import 'dart:async';

import '../application/diagnostics.dart';
import '../domain/models.dart';
import '../ports/ports.dart';
import 'test_server_catalog.dart';

enum MockConnectionScenario {
  success,
  reconnectOnce,
  blockedBySubscription,
  noNetwork,
  serverUnavailable,
  error,
}

enum MockActivationScenario {
  active,
  expired,
  suspended,
  invalidKey,
  noNetwork,
  rateLimited,
  serverError,
}

final class MockActivationApiClient implements ActivationApiClient {
  MockActivationApiClient({this.scenario = MockActivationScenario.active});

  MockActivationScenario scenario;

  @override
  bool get isMock => true;
  int requestCount = 0;

  @override
  Future<ActivationResult> activate(ActivationKey activationKey) async {
    requestCount++;
    switch (scenario) {
      case MockActivationScenario.invalidKey:
        throw const AccountApiException(AccountApiFailure.invalidKey);
      case MockActivationScenario.noNetwork:
        throw const AccountApiException(AccountApiFailure.noNetwork);
      case MockActivationScenario.rateLimited:
        throw const AccountApiException(AccountApiFailure.rateLimited);
      case MockActivationScenario.serverError:
        throw const AccountApiException(AccountApiFailure.server);
      case MockActivationScenario.active:
      case MockActivationScenario.expired:
      case MockActivationScenario.suspended:
        break;
    }
    final DateTime now = DateTime.now().toUtc();
    final SubscriptionStatus status = switch (scenario) {
      MockActivationScenario.expired => SubscriptionStatus.expired,
      MockActivationScenario.suspended => SubscriptionStatus.suspended,
      _ => SubscriptionStatus.active,
    };
    return ActivationResult(
      account: const Account(id: 'mock-account', email: 'demo@kenai.invalid'),
      subscription: Subscription(
        status: status,
        planName: 'Kenai VPN',
        expiresAt: status == SubscriptionStatus.expired
            ? now.subtract(const Duration(days: 1))
            : now.add(const Duration(days: 30)),
        deviceLimit: 1,
        lastVerifiedAt: now,
      ),
      vpnCredentials: const <VpnProtocol, String>{
        VpnProtocol.wireGuard: '[Mock WireGuard profile]',
        VpnProtocol.amneziaWg: '[Mock AmneziaWG profile]',
        VpnProtocol.vlessReality: 'vless://mock.invalid',
      },
    );
  }
}

final class MockApiClient implements ApiClient {
  MockApiClient({this.includeTestServers = false});

  static const bool _isProduct = bool.fromEnvironment('dart.vm.product');
  final bool includeTestServers;

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    if (request.method == ApiMethod.get && request.path == '/mock/v1/servers') {
      return ApiResponse(
        statusCode: 200,
        body: <String, Object?>{
          'mock': true,
          'servers': <Map<String, Object?>>[
            _armenia,
            if (!_isProduct && includeTestServers) ...mockTestServerPayloads,
          ],
        },
      );
    }
    if (request.method == ApiMethod.post &&
        request.path == '/mock/v1/servers/ping') {
      final String? serverId = request.body['server_id'] as String?;
      return ApiResponse(
        statusCode: 200,
        body: <String, Object?>{
          'mock': true,
          'latency_ms': <String, int>{
            'am-evn-01': 36,
            if (!_isProduct) ...mockTestServerLatencies,
          }[serverId],
        },
      );
    }
    return ApiResponse(
      statusCode: 200,
      body: <String, Object?>{
        'mock': true,
        'method': request.method.name,
        'path': request.path,
      },
    );
  }

  static const Map<String, Object?> _armenia = <String, Object?>{
    'id': 'am-evn-01',
    'country_code': 'AM',
    'country_name': 'Армения',
    'city': 'Ереван',
    'name': 'Yerevan S1',
    'protocols': <String>['wireGuard', 'amneziaWg', 'vlessReality'],
    'operational': 'operational',
    'reachability': 'reachable',
    'latency_ms': 38,
    'load_percent': 24,
    'recommended': true,
    'favorite': false,
    'test': false,
  };
}

final class InMemorySecureStorage implements SecureStorage {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> clear() async => _values.clear();

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    _values[key] = value;
  }
}

final class InMemoryDiagnosticLogStore implements DiagnosticLogStore {
  final List<DiagnosticLogEntry> _entries = <DiagnosticLogEntry>[];

  @override
  Future<void> append(DiagnosticLogEntry entry) async => _entries.add(entry);

  @override
  Future<void> clear() async => _entries.clear();

  @override
  Future<List<DiagnosticLogEntry>> readAll() async =>
      List<DiagnosticLogEntry>.unmodifiable(_entries);
}

final class InMemoryDiagnosticArchiveSaver implements DiagnosticArchiveSaver {
  DiagnosticArchive? lastArchive;

  @override
  Future<DiagnosticArchiveLocation> save(DiagnosticArchive archive) async {
    lastArchive = archive;
    return DiagnosticArchiveLocation(path: 'memory://${archive.fileName}');
  }
}

abstract base class MockProtocolAdapter implements VpnProtocolAdapter {
  MockProtocolAdapter(this.protocol);

  @override
  final VpnProtocol protocol;
  int startCount = 0;
  int stopCount = 0;
  String? lastProfileId;

  @override
  VpnAdapterCapabilities get capabilities => VpnAdapterCapabilities(
        protocol: protocol,
        isMock: true,
        supportsKillSwitch: false,
        supportsDns: false,
        supportsNetworkChangeReconnect: false,
        supportsSleepRecovery: false,
      );

  @override
  Future<ProfileValidation> validate(VpnProfile profile) async =>
      ProfileValidation(
        isValid: profile.protocol == protocol &&
            profile.id.trim().isNotEmpty &&
            profile.deviceId.trim().isNotEmpty &&
            profile.serverId.trim().isNotEmpty,
        errorCode: profile.protocol == protocol ? null : 'PROTOCOL_MISMATCH',
      );

  @override
  Future<void> start(VpnProfile profile) async {
    final ProfileValidation validation = await validate(profile);
    if (!validation.isValid) {
      throw StateError('Mock adapter rejected the profile handle');
    }
    startCount++;
    lastProfileId = profile.id;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    lastProfileId = null;
  }
}

final class MockWireGuardAdapter extends MockProtocolAdapter
    implements WireGuardAdapter {
  MockWireGuardAdapter() : super(VpnProtocol.wireGuard);
}

final class MockAmneziaWgAdapter extends MockProtocolAdapter
    implements AmneziaWgAdapter {
  MockAmneziaWgAdapter() : super(VpnProtocol.amneziaWg);
}

final class MockXrayRealityAdapter extends MockProtocolAdapter
    implements XrayRealityAdapter {
  MockXrayRealityAdapter() : super(VpnProtocol.vlessReality);
}

final class MockSettingsRepository implements SettingsRepository {
  MockSettingsRepository({
    AppSettings initialSettings = const AppSettings.defaults(),
  }) : _settings = initialSettings;

  final StreamController<AppSettings> _controller =
      StreamController<AppSettings>.broadcast(sync: true);
  AppSettings _settings;

  @override
  Stream<AppSettings> get changes => _controller.stream;

  @override
  Future<AppSettings> load() async => _settings;

  @override
  Future<void> save(AppSettings settings) async {
    _settings = settings;
    _controller.add(settings);
  }

  Future<void> dispose() => _controller.close();
}

final class MockSpeedTestEngine implements SpeedTestEngine {
  MockSpeedTestEngine({
    this.transitionDelay = const Duration(milliseconds: 120),
  });

  final Duration transitionDelay;
  final StreamController<SpeedTestState> _controller =
      StreamController<SpeedTestState>.broadcast(sync: true);
  SpeedTestState _state = const SpeedTestState.idle();
  int _run = 0;

  @override
  bool get isAvailable => true;

  @override
  bool get isMock => true;

  @override
  SpeedTestState get currentState => _state;

  @override
  Stream<SpeedTestState> get states => _controller.stream;

  @override
  Future<void> start({required String serverId}) async {
    if (_state.phase == SpeedTestPhase.pinging ||
        _state.phase == SpeedTestPhase.downloading ||
        _state.phase == SpeedTestPhase.uploading) {
      throw StateError('A speed test is already active');
    }
    if (serverId.trim().isEmpty) {
      throw ArgumentError.value(serverId, 'serverId', 'Must not be empty');
    }
    final int run = ++_run;
    _emit(
      SpeedTestState(
        phase: SpeedTestPhase.pinging,
        serverId: serverId,
        latencySamples: const <Duration>[
          Duration(milliseconds: 34),
          Duration(milliseconds: 41),
          Duration(milliseconds: 37),
        ],
      ),
    );
    if (!await _wait(run)) return;
    _emit(
      SpeedTestState(
        phase: SpeedTestPhase.downloading,
        serverId: serverId,
        latencySamples: _state.latencySamples,
        downloadMbps: 86.4,
        estimatedBytesUsed: 24 * 1024 * 1024,
      ),
    );
    if (!await _wait(run)) return;
    _emit(
      SpeedTestState(
        phase: SpeedTestPhase.uploading,
        serverId: serverId,
        latencySamples: _state.latencySamples,
        downloadMbps: _state.downloadMbps,
        uploadMbps: 31.7,
        estimatedBytesUsed: 36 * 1024 * 1024,
      ),
    );
    if (!await _wait(run)) return;
    _emit(
      SpeedTestState(
        phase: SpeedTestPhase.completed,
        serverId: serverId,
        latencySamples: _state.latencySamples,
        downloadMbps: _state.downloadMbps,
        uploadMbps: _state.uploadMbps,
        estimatedBytesUsed: _state.estimatedBytesUsed,
      ),
    );
  }

  @override
  Future<void> stop() async {
    if (_state.phase != SpeedTestPhase.pinging &&
        _state.phase != SpeedTestPhase.downloading &&
        _state.phase != SpeedTestPhase.uploading) {
      return;
    }
    _run++;
    _emit(
      SpeedTestState(
        phase: SpeedTestPhase.cancelled,
        serverId: _state.serverId,
        latencySamples: _state.latencySamples,
        downloadMbps: _state.downloadMbps,
        uploadMbps: _state.uploadMbps,
        estimatedBytesUsed: _state.estimatedBytesUsed,
      ),
    );
  }

  Future<bool> _wait(int run) async {
    await Future<void>.delayed(transitionDelay);
    return run == _run;
  }

  void _emit(SpeedTestState state) {
    _state = state;
    _controller.add(state);
  }

  Future<void> dispose() => _controller.close();
}

final class UnavailableSpeedTestEngine implements SpeedTestEngine {
  final StreamController<SpeedTestState> _controller =
      StreamController<SpeedTestState>.broadcast(sync: true);
  SpeedTestState _state = const SpeedTestState.idle();

  @override
  bool get isAvailable => false;

  @override
  bool get isMock => false;

  @override
  SpeedTestState get currentState => _state;

  @override
  Stream<SpeedTestState> get states => _controller.stream;

  @override
  Future<void> start({required String serverId}) async {
    _state = SpeedTestState(
      phase: SpeedTestPhase.failed,
      serverId: serverId,
      errorCode: 'SPEED_TEST_BACKEND_UNAVAILABLE',
    );
    _controller.add(_state);
  }

  @override
  Future<void> stop() async {}

  Future<void> dispose() => _controller.close();
}

final class MockUpdateProvider implements UpdateProvider {
  MockUpdateProvider({
    this.result = const UpdateCheckResult(
      status: UpdateStatus.upToDate,
      currentVersion: '0.1.0',
      latestVersion: '0.1.0',
      safeMessage:
          'Development mock: updates were not requested from a server.',
    ),
  });

  final UpdateCheckResult result;

  @override
  bool get isAvailable => true;

  @override
  bool get isMock => true;

  @override
  bool get verifiesSignatures => false;

  @override
  Future<UpdateCheckResult> checkForUpdates() async => result;
}

final class UnavailableUpdateProvider implements UpdateProvider {
  UnavailableUpdateProvider({required this.currentVersion});

  final String currentVersion;

  @override
  bool get isAvailable => false;

  @override
  bool get isMock => false;

  @override
  bool get verifiesSignatures => false;

  @override
  Future<UpdateCheckResult> checkForUpdates() async => UpdateCheckResult(
        status: UpdateStatus.unavailable,
        currentVersion: currentVersion,
        safeMessage: 'A signed update provider is not configured.',
      );
}

final class MockVpnEngine implements VpnEngine {
  MockVpnEngine({
    this.scenario = MockConnectionScenario.success,
    VpnConnectionState initialState = const VpnConnectionState.disconnected(),
    Duration transitionDelay = const Duration(milliseconds: 80),
    List<VpnProtocolAdapter>? adapters,
  })  : _state = initialState,
        _adapters = <VpnProtocol, VpnProtocolAdapter>{
          for (final VpnProtocolAdapter adapter in adapters ??
              <VpnProtocolAdapter>[
                MockWireGuardAdapter(),
                MockAmneziaWgAdapter(),
                MockXrayRealityAdapter(),
              ])
            adapter.protocol: adapter,
        },
        _transitionDelay = transitionDelay;

  final StreamController<VpnConnectionState> _controller =
      StreamController<VpnConnectionState>.broadcast(sync: true);
  final Duration _transitionDelay;
  final Map<VpnProtocol, VpnProtocolAdapter> _adapters;
  MockConnectionScenario scenario;
  VpnConnectionState _state;
  bool _operationInFlight = false;
  int _statisticsTick = 0;

  @override
  bool get isMock => true;

  @override
  Set<VpnProtocol> get supportedProtocols =>
      Set<VpnProtocol>.unmodifiable(_adapters.keys);

  @override
  VpnAdapterCapabilities capabilitiesFor(VpnProtocol protocol) {
    final VpnProtocolAdapter? adapter = _adapters[protocol];
    if (adapter == null) {
      throw ArgumentError.value(protocol, 'protocol', 'Unsupported protocol');
    }
    return adapter.capabilities;
  }

  @override
  Stream<VpnConnectionState> get states => _controller.stream;

  @override
  Future<void> connect(ConnectionRequest request) async {
    if (_operationInFlight ||
        _state.phase == VpnConnectionPhase.connected ||
        _state.phase.isBusy) {
      throw StateError('A VPN operation is already active');
    }
    _validateOperationId(request.operationId);
    _operationInFlight = true;
    try {
      _emitForRequest(VpnConnectionPhase.validating, request);
      await Future<void>.delayed(_transitionDelay);
      final ProfileValidation validation = await validateProfile(
        request.profile,
      );
      if (!validation.isValid) {
        _emitForRequest(
          VpnConnectionPhase.error,
          request,
          errorCode: validation.errorCode,
        );
        return;
      }
      final VpnConnectionPhase? failure = _failurePhaseForScenario();
      if (failure != null) {
        _emitForRequest(failure, request, errorCode: _errorCodeFor(failure));
        return;
      }
      _emitForRequest(VpnConnectionPhase.connecting, request);
      await Future<void>.delayed(_transitionDelay);
      await _adapters[request.profile.protocol]!.start(request.profile);
      _emitConnected(request);
      if (scenario == MockConnectionScenario.reconnectOnce) {
        await Future<void>.delayed(_transitionDelay);
        _emitForRequest(VpnConnectionPhase.reconnecting, request);
        await Future<void>.delayed(_transitionDelay);
        _emitConnected(request);
      }
    } finally {
      _operationInFlight = false;
    }
  }

  @override
  Future<void> disconnect({required String operationId}) async {
    if (_operationInFlight ||
        (_state.phase != VpnConnectionPhase.connected &&
            _state.phase != VpnConnectionPhase.reconnecting)) {
      throw StateError('A VPN operation is already active');
    }
    _validateOperationId(operationId);
    _operationInFlight = true;
    try {
      _emit(
        VpnConnectionState(
          phase: VpnConnectionPhase.disconnecting,
          serverId: _state.serverId,
          protocol: _state.protocol,
          connectedAt: _state.connectedAt,
          killSwitchActive: _state.killSwitchActive,
        ),
      );
      await Future<void>.delayed(_transitionDelay);
      final VpnProtocol? protocol = _state.protocol;
      if (protocol != null) await _adapters[protocol]?.stop();
      _statisticsTick = 0;
      _emit(const VpnConnectionState.disconnected());
    } finally {
      _operationInFlight = false;
    }
  }

  @override
  Future<VpnConnectionState> status() async => _state;

  @override
  Future<VpnStatistics> statistics() async {
    if (_state.phase == VpnConnectionPhase.connected) _statisticsTick++;
    return VpnStatistics(
      bytesReceived: _statisticsTick * 1024 * 1024,
      bytesSent: _statisticsTick * 384 * 1024,
      measuredAt: DateTime.now(),
    );
  }

  @override
  Future<ProfileValidation> validateProfile(VpnProfile profile) async {
    final VpnProtocolAdapter? adapter = _adapters[profile.protocol];
    if (adapter == null) {
      return const ProfileValidation(
        isValid: false,
        errorCode: 'UNSUPPORTED_PROTOCOL',
      );
    }
    return adapter.validate(profile);
  }

  @override
  Future<EngineDiagnostics> collectDiagnostics() async => EngineDiagnostics(
        phase: _state.phase,
        serviceAvailable: true,
        networkAvailable: _state.phase != VpnConnectionPhase.noNetwork,
        codes: const <String>['MOCK_ENGINE'],
      );

  void simulateState(VpnConnectionState state) => _emit(state);

  Future<void> dispose() => _controller.close();

  VpnConnectionPhase? _failurePhaseForScenario() => switch (scenario) {
        MockConnectionScenario.blockedBySubscription =>
          VpnConnectionPhase.blockedBySubscription,
        MockConnectionScenario.noNetwork => VpnConnectionPhase.noNetwork,
        MockConnectionScenario.serverUnavailable =>
          VpnConnectionPhase.serverUnavailable,
        MockConnectionScenario.error => VpnConnectionPhase.error,
        MockConnectionScenario.success ||
        MockConnectionScenario.reconnectOnce =>
          null,
      };

  String _errorCodeFor(VpnConnectionPhase phase) => switch (phase) {
        VpnConnectionPhase.blockedBySubscription => 'SUBSCRIPTION_INACTIVE',
        VpnConnectionPhase.noNetwork => 'NETWORK_UNAVAILABLE',
        VpnConnectionPhase.serverUnavailable => 'SERVER_UNAVAILABLE',
        _ => 'MOCK_CONNECTION_FAILED',
      };

  void _emitForRequest(
    VpnConnectionPhase phase,
    ConnectionRequest request, {
    String? errorCode,
  }) {
    _emit(
      VpnConnectionState(
        phase: phase,
        serverId: request.profile.serverId,
        protocol: request.profile.protocol,
        connectedAt: phase == VpnConnectionPhase.reconnecting
            ? _state.connectedAt
            : null,
        killSwitchActive:
            phase == VpnConnectionPhase.reconnecting && _state.killSwitchActive,
        errorCode: errorCode,
      ),
    );
  }

  void _emitConnected(ConnectionRequest request) {
    _emit(
      VpnConnectionState(
        phase: VpnConnectionPhase.connected,
        serverId: request.profile.serverId,
        protocol: request.profile.protocol,
        connectedAt: _state.connectedAt ?? DateTime.now(),
        killSwitchActive: request.killSwitch,
      ),
    );
  }

  void _emit(VpnConnectionState state) {
    _state = state;
    _controller.add(state);
  }

  static void _validateOperationId(String operationId) {
    if (operationId.trim().isEmpty) {
      throw ArgumentError.value(
        operationId,
        'operationId',
        'Must not be empty',
      );
    }
  }
}

final class MockServerRepository implements ServerRepository {
  MockServerRepository({ApiClient? apiClient})
      : _apiClient = apiClient ?? MockApiClient();

  final ApiClient _apiClient;

  @override
  bool get isMock => true;
  final List<VpnServer> _servers = <VpnServer>[];
  bool _loaded = false;
  String? _selectedServerId = 'am-evn-01';

  @override
  Future<VpnServer?> getSelectedServer() async {
    await _ensureLoaded();
    for (final VpnServer server in _servers) {
      if (server.id == _selectedServerId) return server;
    }
    return _servers.isEmpty ? null : _servers.first;
  }

  @override
  Future<List<VpnServer>> getServers({
    String query = '',
    ServerSort sort = ServerSort.recommended,
    String? countryCode,
    bool favoritesOnly = false,
  }) async {
    await _ensureLoaded();
    final String normalized = query.trim().toLowerCase();
    final List<VpnServer> result = _servers
        .where(
          (VpnServer server) =>
              (normalized.isEmpty ||
                  server.countryName.toLowerCase().contains(normalized) ||
                  server.city.toLowerCase().contains(normalized) ||
                  server.name.toLowerCase().contains(normalized)) &&
              (countryCode == null || server.countryCode == countryCode) &&
              (!favoritesOnly || server.isFavorite),
        )
        .toList(growable: false);
    result.sort(_comparator(sort));
    return List<VpnServer>.unmodifiable(result);
  }

  @override
  Future<void> selectServer(String serverId) async {
    await _ensureLoaded();
    _serverIndex(serverId);
    _selectedServerId = serverId;
  }

  @override
  Future<void> toggleFavorite(String serverId) async {
    await _ensureLoaded();
    final int index = _serverIndex(serverId);
    _servers[index] = _servers[index].copyWith(
      isFavorite: !_servers[index].isFavorite,
    );
  }

  @override
  Future<Duration?> ping(String serverId) async {
    await _ensureLoaded();
    final int index = _serverIndex(serverId);
    final ApiResponse response = await _apiClient.send(
      ApiRequest(
        method: ApiMethod.post,
        path: '/mock/v1/servers/ping',
        body: <String, Object?>{'server_id': serverId},
      ),
    );
    final int? latencyMs = response.body['latency_ms'] as int?;
    if (latencyMs == null) return null;
    final Duration latency = Duration(milliseconds: latencyMs);
    _servers[index] = _servers[index].copyWith(
      status: _servers[index].status.copyWith(latency: latency),
    );
    return latency;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final ApiResponse response = await _apiClient.send(
      const ApiRequest(method: ApiMethod.get, path: '/mock/v1/servers'),
    );
    if (response.statusCode != 200 || response.body['mock'] != true) {
      throw StateError('Mock server catalog is unavailable');
    }
    final List<Object?> payload = response.body['servers']! as List<Object?>;
    _servers.addAll(payload.map(_decodeServer));
    _loaded = true;
  }

  int _serverIndex(String serverId) {
    final int index = _servers.indexWhere(
      (VpnServer server) => server.id == serverId,
    );
    if (index < 0) {
      throw ArgumentError.value(serverId, 'serverId', 'Unknown mock server');
    }
    return index;
  }

  static VpnServer _decodeServer(Object? value) {
    final Map<String, Object?> data = value! as Map<String, Object?>;
    final List<Object?> protocols = data['protocols']! as List<Object?>;
    return VpnServer(
      id: data['id']! as String,
      countryCode: data['country_code']! as String,
      countryName: data['country_name']! as String,
      city: data['city']! as String,
      name: data['name']! as String,
      protocols: protocols
          .map((Object? protocol) => _protocol(protocol! as String))
          .toSet(),
      status: ServerStatus(
        operational: _operational(data['operational']! as String),
        internetReachability: _reachability(data['reachability']! as String),
        lastUpdatedAt: DateTime.now().toUtc(),
        latency: switch (data['latency_ms']) {
          final int milliseconds => Duration(milliseconds: milliseconds),
          _ => null,
        },
        loadPercent: data['load_percent'] as int?,
      ),
      isRecommended: data['recommended']! as bool,
      isFavorite: data['favorite']! as bool,
      isTest: data['test']! as bool,
    );
  }

  static Comparator<VpnServer> _comparator(ServerSort sort) {
    int byLatency(VpnServer left, VpnServer right) {
      final int leftMs = left.status.latency?.inMilliseconds ?? 1 << 30;
      final int rightMs = right.status.latency?.inMilliseconds ?? 1 << 30;
      return leftMs.compareTo(rightMs);
    }

    return switch (sort) {
      ServerSort.recommended => (VpnServer left, VpnServer right) {
          final int recommended = (right.isRecommended ? 1 : 0).compareTo(
            left.isRecommended ? 1 : 0,
          );
          if (recommended != 0) return recommended;
          final int availability = (right.isAvailable ? 1 : 0).compareTo(
            left.isAvailable ? 1 : 0,
          );
          return availability != 0 ? availability : byLatency(left, right);
        },
      ServerSort.latency => byLatency,
      ServerSort.name => (VpnServer left, VpnServer right) =>
          left.name.compareTo(right.name),
      ServerSort.country => (VpnServer left, VpnServer right) =>
          left.countryName.compareTo(right.countryName),
    };
  }

  static VpnProtocol _protocol(String value) => switch (value) {
        'wireGuard' => VpnProtocol.wireGuard,
        'amneziaWg' => VpnProtocol.amneziaWg,
        'vlessReality' => VpnProtocol.vlessReality,
        _ => throw const FormatException('Unknown mock protocol'),
      };

  static ServerOperationalStatus _operational(String value) => switch (value) {
        'operational' => ServerOperationalStatus.operational,
        'degraded' => ServerOperationalStatus.degraded,
        'maintenance' => ServerOperationalStatus.maintenance,
        'offline' => ServerOperationalStatus.offline,
        _ => ServerOperationalStatus.unknown,
      };

  static InternetReachability _reachability(String value) => switch (value) {
        'reachable' => InternetReachability.reachable,
        'unreachable' => InternetReachability.unreachable,
        _ => InternetReachability.unknown,
      };
}

final class MockSubscriptionRepository implements SubscriptionRepository {
  @override
  Future<Subscription> getSubscription() async => Subscription(
        status: SubscriptionStatus.active,
        planName: 'Kenai VPN',
        expiresAt: DateTime(2026, 10, 5),
        deviceLimit: 1,
        lastVerifiedAt: DateTime.utc(2026, 9, 5),
      );
}

enum MockPaymentScenario { success, orderFailure, confirmationFailure }

final class MockPaymentProvider implements PaymentProvider {
  MockPaymentProvider({
    this.scenario = MockPaymentScenario.success,
    Duration transitionDelay = const Duration(milliseconds: 60),
  }) : _transitionDelay = transitionDelay;

  final StreamController<PaymentState> _controller =
      StreamController<PaymentState>.broadcast(sync: true);
  final Duration _transitionDelay;
  MockPaymentScenario scenario;
  PaymentState _state = const PaymentState.idle();

  @override
  bool get isAvailable => true;

  @override
  bool get isMock => true;

  @override
  PaymentState get currentState => _state;

  @override
  Stream<PaymentState> get states => _controller.stream;

  @override
  Future<PaymentSession> createCheckout({required String planId}) async {
    _emit(const PaymentState(phase: PaymentPhase.creatingOrder));
    await Future<void>.delayed(_transitionDelay);
    if (scenario == MockPaymentScenario.orderFailure) {
      _emit(
        const PaymentState(
          phase: PaymentPhase.failed,
          failure: PaymentFailure.orderCreation,
        ),
      );
      throw const PaymentException(PaymentFailure.orderCreation);
    }
    final PaymentSession session = PaymentSession(
      id: 'mock-$planId',
      checkoutUri: Uri.parse('https://example.invalid/mock-checkout/$planId'),
    );
    _emit(
      PaymentState(
        phase: PaymentPhase.awaitingPayment,
        session: session,
      ),
    );
    return session;
  }

  @override
  Future<bool> confirm(String sessionId) async {
    if (_state.phase != PaymentPhase.awaitingPayment ||
        _state.session?.id != sessionId) {
      throw const PaymentException(PaymentFailure.confirmation);
    }
    await Future<void>.delayed(_transitionDelay);
    if (scenario == MockPaymentScenario.confirmationFailure) {
      _emit(
        const PaymentState(
          phase: PaymentPhase.failed,
          failure: PaymentFailure.confirmation,
        ),
      );
      return false;
    }
    _emit(PaymentState(phase: PaymentPhase.paid, session: _state.session));
    await Future<void>.delayed(_transitionDelay);
    _emit(
      PaymentState(
        phase: PaymentPhase.subscriptionUpdating,
        session: _state.session,
      ),
    );
    await Future<void>.delayed(_transitionDelay);
    _emit(PaymentState(phase: PaymentPhase.paid, session: _state.session));
    return true;
  }

  @override
  Future<void> cancel(String sessionId) async {
    if (_state.session?.id != sessionId) return;
    _emit(
      PaymentState(
        phase: PaymentPhase.cancelled,
        session: _state.session,
      ),
    );
  }

  Future<void> dispose() => _controller.close();

  void _emit(PaymentState state) {
    _state = state;
    _controller.add(state);
  }
}

final class UnavailablePaymentProvider implements PaymentProvider {
  final StreamController<PaymentState> _controller =
      StreamController<PaymentState>.broadcast(sync: true);
  PaymentState _state = const PaymentState.idle();

  @override
  bool get isAvailable => false;

  @override
  bool get isMock => false;

  @override
  PaymentState get currentState => _state;

  @override
  Stream<PaymentState> get states => _controller.stream;

  @override
  Future<PaymentSession> createCheckout({required String planId}) async {
    _state = const PaymentState(
      phase: PaymentPhase.failed,
      failure: PaymentFailure.backendUnavailable,
    );
    _controller.add(_state);
    throw const PaymentException(PaymentFailure.backendUnavailable);
  }

  @override
  Future<bool> confirm(String sessionId) async => false;

  @override
  Future<void> cancel(String sessionId) async {}

  Future<void> dispose() => _controller.close();
}

final class MockDiagnosticExporter implements DiagnosticExporter {
  final RedactingDiagnostics _delegate = RedactingDiagnostics(
    store: InMemoryDiagnosticLogStore(),
  );

  @override
  Future<DiagnosticArchive> createArchive() => _delegate.createArchive();

  @override
  Future<DiagnosticPreview> preview() => _delegate.preview();

  Future<void> dispose() => _delegate.dispose();
}
