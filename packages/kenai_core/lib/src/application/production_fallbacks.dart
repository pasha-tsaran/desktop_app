import 'dart:async';

import '../domain/models.dart';
import '../ports/ports.dart';

/// Fail-closed transport used when a release was built without an API URL.
final class UnavailableApiClient implements ApiClient {
  const UnavailableApiClient();

  @override
  Future<ApiResponse> send(ApiRequest request) =>
      throw const ApiClientException(ApiTransportFailure.unavailable);
}

final class UnavailableSubscriptionRepository
    implements SubscriptionRepository {
  const UnavailableSubscriptionRepository();

  @override
  Future<Subscription> getSubscription() =>
      throw StateError('Subscription API is unavailable');
}

/// Honest release fallback until the Windows IPC engine is connected.
final class UnavailableVpnEngine implements VpnEngine {
  final StreamController<VpnConnectionState> _states =
      StreamController<VpnConnectionState>.broadcast(sync: true);
  VpnConnectionState _state = const VpnConnectionState.disconnected();

  @override
  bool get isMock => false;

  @override
  Set<VpnProtocol> get supportedProtocols => const <VpnProtocol>{};

  @override
  Stream<VpnConnectionState> get states => _states.stream;

  @override
  VpnAdapterCapabilities capabilitiesFor(VpnProtocol protocol) =>
      VpnAdapterCapabilities(
        protocol: protocol,
        isMock: false,
        supportsKillSwitch: false,
        supportsDns: false,
        supportsNetworkChangeReconnect: false,
        supportsSleepRecovery: false,
      );

  @override
  Future<void> connect(ConnectionRequest request) async {
    _state = VpnConnectionState(
      phase: VpnConnectionPhase.error,
      serverId: request.profile.serverId,
      protocol: request.profile.protocol,
      errorCode: 'ENGINE_NOT_INSTALLED',
    );
    _states.add(_state);
  }

  @override
  Future<void> disconnect({required String operationId}) async {
    _state = const VpnConnectionState.disconnected();
    _states.add(_state);
  }

  @override
  Future<VpnConnectionState> status() async => _state;

  @override
  Future<VpnStatistics> statistics() async =>
      VpnStatistics(bytesReceived: 0, bytesSent: 0, measuredAt: DateTime.now());

  @override
  Future<ProfileValidation> validateProfile(VpnProfile profile) async =>
      const ProfileValidation(
        isValid: false,
        errorCode: 'ENGINE_NOT_INSTALLED',
      );

  @override
  Future<EngineDiagnostics> collectDiagnostics() async => EngineDiagnostics(
        phase: _state.phase,
        serviceAvailable: false,
        networkAvailable: true,
        codes: const <String>['ENGINE_NOT_INSTALLED'],
      );
}

/// Direct production exits. A selected location must have its own VPN profile.
final class ArmeniaMvpServerRepository implements ServerRepository {
  ArmeniaMvpServerRepository({
    ServerLatencyProbe? latencyProbe,
    ServerLatencyProbe? netherlandsLatencyProbe,
  })  : _latencyProbe = latencyProbe ?? const UnavailableServerLatencyProbe(),
        _netherlandsLatencyProbe =
            netherlandsLatencyProbe ?? const UnavailableServerLatencyProbe();

  final ServerLatencyProbe _latencyProbe;
  final ServerLatencyProbe _netherlandsLatencyProbe;

  VpnServer _server = VpnServer(
    id: 'armenia-1',
    countryCode: 'AM',
    countryName: 'Армения',
    city: 'Ереван',
    name: 'Армения',
    protocols: const <VpnProtocol>{
      VpnProtocol.vlessReality,
      VpnProtocol.amneziaWg,
    },
    status: ServerStatus(
      operational: ServerOperationalStatus.unknown,
      internetReachability: InternetReachability.unknown,
      lastUpdatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    ),
    isRecommended: true,
  );
  VpnServer _netherlands = VpnServer(
    id: 'netherlands-1',
    countryCode: 'NL',
    countryName: 'Нидерланды',
    city: 'Амстердам',
    name: 'Нидерланды',
    protocols: const <VpnProtocol>{
      VpnProtocol.amneziaWg,
      VpnProtocol.vlessReality,
    },
    status: ServerStatus(
      operational: ServerOperationalStatus.unknown,
      internetReachability: InternetReachability.unknown,
      lastUpdatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    ),
  );
  String _selectedId = 'armenia-1';

  @override
  bool get isMock => false;

  @override
  Future<List<VpnServer>> getServers({
    String query = '',
    ServerSort sort = ServerSort.recommended,
    String? countryCode,
    bool favoritesOnly = false,
  }) async {
    final String normalized = query.trim().toLowerCase();
    return <VpnServer>[_server, _netherlands].where((server) {
      final bool matchesQuery = normalized.isEmpty ||
          server.countryName.toLowerCase().contains(normalized) ||
          server.city.toLowerCase().contains(normalized);
      return matchesQuery &&
          (countryCode == null || server.countryCode == countryCode) &&
          (!favoritesOnly || server.isFavorite);
    }).toList();
  }

  @override
  Future<VpnServer?> getSelectedServer() async =>
      _selectedId == _netherlands.id ? _netherlands : _server;

  @override
  Future<void> selectServer(String serverId) async {
    _requireCurrent(serverId);
    _selectedId = serverId;
  }

  @override
  Future<void> toggleFavorite(String serverId) async {
    _requireCurrent(serverId);
    if (serverId == _netherlands.id) {
      _netherlands = _netherlands.copyWith(
        isFavorite: !_netherlands.isFavorite,
      );
    } else {
      _server = _server.copyWith(isFavorite: !_server.isFavorite);
    }
  }

  @override
  Future<Duration?> ping(String serverId) async {
    _requireCurrent(serverId);
    final VpnServer server =
        serverId == _netherlands.id ? _netherlands : _server;
    final ServerStatus previous = server.status;
    final VpnServer updated = server.copyWith(
      status: ServerStatus(
        operational: previous.operational,
        internetReachability: previous.internetReachability,
        lastUpdatedAt: DateTime.now().toUtc(),
        loadPercent: previous.loadPercent,
      ),
    );
    final Duration? latency = await (serverId == _server.id
            ? _latencyProbe
            : _netherlandsLatencyProbe)
        .measure();
    if (serverId == _netherlands.id) {
      _netherlands = updated.copyWith(
        status: updated.status.copyWith(latency: latency),
      );
    } else {
      _server = updated.copyWith(
        status: updated.status.copyWith(latency: latency),
      );
    }
    return latency;
  }

  void _requireCurrent(String serverId) {
    if (serverId != _server.id && serverId != _netherlands.id) {
      throw ArgumentError.value(serverId, 'serverId', 'Unknown server');
    }
  }
}

final class UnavailableServerLatencyProbe implements ServerLatencyProbe {
  const UnavailableServerLatencyProbe();

  @override
  Future<Duration?> measure() async => null;
}
