import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:kenai_core/kenai_core.dart';

import 'windows_profile_provisioner.dart';

/// Production VPN engine backed only by the typed Kenai Windows service IPC.
///
/// It never receives a configuration or secret. The privileged service resolves
/// the opaque profile handle created after successful account activation.
final class WindowsVpnEngine
    implements VpnEngine, SystemVpnEngine, CancellableVpnEngine {
  WindowsVpnEngine({
    required SecureStorage secureStorage,
    // SCM start/stop may each take 30s, followed by a 15s AWG handshake check.
    // Keep activation/profile-storage IPC on its separate, shorter deadline.
    ProfileIpcTransport transport = const WindowsNamedPipeProfileTransport(
      timeout: Duration(seconds: 90),
    ),
    Random? random,
  }) : _secureStorage = secureStorage,
       _transport = transport,
       _random = random ?? Random.secure();

  final SecureStorage _secureStorage;
  final ProfileIpcTransport _transport;
  final Random _random;
  final StreamController<VpnConnectionState> _states =
      StreamController<VpnConnectionState>.broadcast(sync: true);

  VpnConnectionState _state = const VpnConnectionState.disconnected();
  bool _operationInFlight = false;
  int _generation = 0;
  String? _connectOperation;
  Future<void>? _disconnecting;
  String? _serverId;
  VpnProtocol? _protocol;
  DateTime? _connectedAt;

  @override
  bool get isMock => false;

  @override
  Set<VpnProtocol> get supportedProtocols => const <VpnProtocol>{
    VpnProtocol.wireGuard,
    VpnProtocol.amneziaWg,
    VpnProtocol.vlessReality,
  };

  @override
  Stream<VpnConnectionState> get states => _states.stream;

  @override
  VpnAdapterCapabilities capabilitiesFor(VpnProtocol protocol) =>
      VpnAdapterCapabilities(
        protocol: protocol,
        isMock: false,
        supportsKillSwitch: true,
        supportsDns: false,
        supportsNetworkChangeReconnect: true,
        supportsSleepRecovery: true,
      );

  @override
  Future<void> connect(ConnectionRequest request) async {
    if (_operationInFlight || _disconnecting != null || _state.phase.isBusy) {
      throw StateError('VPN operation is already in progress');
    }
    _operationInFlight = true;
    final generation = ++_generation;
    _connectOperation = request.operationId;
    _serverId = request.profile.serverId;
    _protocol = request.profile.protocol;
    try {
      if (!supportedProtocols.contains(request.profile.protocol)) {
        _emitFailure('UNSUPPORTED_PROTOCOL');
        return;
      }
      _emit(VpnConnectionPhase.validating);
      final _AccountAccess access = await _accountAccess();
      if (generation != _generation) return;
      if (!access.active) {
        _emitFailure('SUBSCRIPTION_REQUIRED');
        return;
      }
      final String? profileHandle = switch (request.profile.protocol) {
        VpnProtocol.wireGuard => access.profileHandle,
        VpnProtocol.amneziaWg => switch (request.profile.serverId) {
          'armenia-1' => access.amneziaWgProfileHandle,
          'netherlands-1' => access.netherlandsAmneziaWgProfileHandle,
          _ => null,
        },
        VpnProtocol.vlessReality => switch (request.profile.serverId) {
          'armenia-1' => access.vlessProfileHandle,
          'netherlands-1' => access.netherlandsVlessProfileHandle,
          _ => null,
        },
      };
      if (profileHandle == null || !_validIdentifier(profileHandle)) {
        _emitFailure('PROFILE_NOT_FOUND');
        return;
      }
      _emit(VpnConnectionPhase.connecting);
      final VpnIpcResponse response = await _exchange(
        2,
        Uint8List.fromList(<int>[
          ..._identifierBytes(request.operationId),
          ..._identifierBytes(profileHandle),
          switch (request.profile.protocol) {
            VpnProtocol.wireGuard => 1,
            VpnProtocol.amneziaWg => 2,
            VpnProtocol.vlessReality => 3,
          },
          request.killSwitch ? 1 : 0,
        ]),
      );
      if (generation == _generation) _apply(response);
    } on ProfileProvisioningException catch (error) {
      if (generation == _generation) _emitFailure(error.code);
    } on Object {
      if (generation == _generation) _emitFailure('ENGINE_FAILED');
    } finally {
      _operationInFlight = false;
      _connectOperation = null;
    }
  }

  @override
  Future<void> disconnect({required String operationId}) {
    if (_disconnecting != null) return _disconnecting!;
    ++_generation;
    final future = _disconnect(_connectOperation ?? operationId);
    _disconnecting = future;
    return future.whenComplete(() => _disconnecting = null);
  }

  @override
  Future<void> cancelConnection({required String operationId}) =>
      disconnect(operationId: operationId);

  Future<void> _disconnect(String operationId) async {
    try {
      _emit(VpnConnectionPhase.disconnecting);
      final VpnIpcResponse response = await _exchange(
        3,
        _identifierBytes(operationId),
      );
      _apply(response);
      if (response.phase != 0) {
        throw ProfileProvisioningException(response.code);
      }
    } on ProfileProvisioningException catch (error) {
      _emitFailure(error.code);
      rethrow;
    } on Object {
      _emitFailure('ENGINE_FAILED');
      rethrow;
    }
  }

  @override
  Future<void> configureKillSwitch(bool enabled) async {
    final response = await _exchange(
      10,
      Uint8List.fromList(<int>[enabled ? 1 : 0]),
    );
    if (response.code != 'OK')
      throw ProfileProvisioningException(response.code);
    _apply(response);
  }

  @override
  Future<VpnConnectionState> status() async {
    if (_operationInFlight || _disconnecting != null) return _state;
    final generation = _generation;
    try {
      final VpnIpcResponse response = await _exchange(1, Uint8List(0));
      if (generation == _generation) {
        if (_serverId == null && response.profileId != null) {
          final String? netherlandsHandle = await _secureStorage.read(
            SecureAccountStorageKeys.netherlandsVlessProfileHandle,
          );
          final String? netherlandsAwgHandle = await _secureStorage.read(
            SecureAccountStorageKeys.netherlandsAmneziaWgProfileHandle,
          );
          if (generation != _generation) return _state;
          if (response.profileId == netherlandsHandle ||
              response.profileId == netherlandsAwgHandle) {
            _serverId = 'netherlands-1';
          }
        }
        _apply(response);
      }
    } on ProfileProvisioningException catch (error) {
      if (generation == _generation) _emitFailure(error.code);
    } on Object {
      if (generation == _generation) _emitFailure('ENGINE_FAILED');
    }
    return _state;
  }

  @override
  Future<VpnStatistics> statistics() async {
    if (_state.phase != VpnConnectionPhase.connected) {
      return _emptyStatistics();
    }
    try {
      final VpnIpcResponse response = await _exchange(7, Uint8List(0));
      if (response.code != 'OK' ||
          response.bytesReceived == null ||
          response.bytesSent == null) {
        return _emptyStatistics();
      }
      return VpnStatistics(
        bytesReceived: response.bytesReceived!,
        bytesSent: response.bytesSent!,
        measuredAt: DateTime.now(),
      );
    } on Object {
      return _emptyStatistics();
    }
  }

  @override
  Future<ProfileValidation> validateProfile(VpnProfile profile) async {
    if (!supportedProtocols.contains(profile.protocol)) {
      return const ProfileValidation(
        isValid: false,
        errorCode: 'UNSUPPORTED_PROTOCOL',
      );
    }
    final _AccountAccess access = await _accountAccess();
    final String? handle = switch (profile.protocol) {
      VpnProtocol.wireGuard => access.profileHandle,
      VpnProtocol.amneziaWg => switch (profile.serverId) {
        'armenia-1' => access.amneziaWgProfileHandle,
        'netherlands-1' => access.netherlandsAmneziaWgProfileHandle,
        _ => null,
      },
      VpnProtocol.vlessReality => switch (profile.serverId) {
        'armenia-1' => access.vlessProfileHandle,
        'netherlands-1' => access.netherlandsVlessProfileHandle,
        _ => null,
      },
    };
    return ProfileValidation(
      isValid: access.active && handle != null,
      errorCode: !access.active
          ? 'SUBSCRIPTION_REQUIRED'
          : handle == null
          ? 'PROFILE_NOT_FOUND'
          : null,
    );
  }

  @override
  Future<EngineDiagnostics> collectDiagnostics() async => EngineDiagnostics(
    phase: _state.phase,
    serviceAvailable: _state.errorCode != 'SERVICE_UNAVAILABLE',
    networkAvailable: _state.phase != VpnConnectionPhase.noNetwork,
    codes: _state.errorCode == null
        ? const <String>[]
        : <String>[_state.errorCode!],
  );

  Future<VpnIpcResponse> _exchange(int opcode, Uint8List commandBody) async {
    final String requestId = _identifier('request');
    final Uint8List body = Uint8List.fromList(<int>[
      ..._identifierBytes(requestId),
      ...commandBody,
    ]);
    final Uint8List response = await _transport.exchange(
      encodeVpnIpcFrame(opcode, body),
    );
    return decodeVpnIpcResponse(response, requestId);
  }

  Future<_AccountAccess> _accountAccess() async {
    final String? encoded = await _secureStorage.read(
      SecureAccountStorageKeys.session,
    );
    final String? handle = await _secureStorage.read(
      SecureAccountStorageKeys.profileHandle,
    );
    final String? amneziaWgHandle = await _secureStorage.read(
      SecureAccountStorageKeys.amneziaWgProfileHandle,
    );
    final String? vlessHandle = await _secureStorage.read(
      SecureAccountStorageKeys.vlessProfileHandle,
    );
    final String? netherlandsVlessHandle = await _secureStorage.read(
      SecureAccountStorageKeys.netherlandsVlessProfileHandle,
    );
    final String? netherlandsAmneziaWgHandle = await _secureStorage.read(
      SecureAccountStorageKeys.netherlandsAmneziaWgProfileHandle,
    );
    if (encoded == null) return const _AccountAccess(active: false);
    try {
      final Object? decoded = jsonDecode(encoded);
      if (decoded is! Map<String, Object?>) {
        return const _AccountAccess(active: false);
      }
      final Object? subscription = decoded['subscription'];
      final bool active =
          subscription is Map<String, Object?> &&
          subscription['status'] == SubscriptionStatus.active.name;
      return _AccountAccess(
        active: active,
        profileHandle: handle,
        amneziaWgProfileHandle: amneziaWgHandle,
        vlessProfileHandle: vlessHandle,
        netherlandsVlessProfileHandle: netherlandsVlessHandle,
        netherlandsAmneziaWgProfileHandle: netherlandsAmneziaWgHandle,
      );
    } on FormatException {
      return const _AccountAccess(active: false);
    }
  }

  void _apply(VpnIpcResponse response) {
    final VpnConnectionPhase phase = _phase(response.phase);
    if (phase == VpnConnectionPhase.connected) {
      if (_protocol == null && response.profileId != null) {
        if (response.profileId!.startsWith('awg-'))
          _protocol = VpnProtocol.amneziaWg;
        if (response.profileId!.startsWith('xray-'))
          _protocol = VpnProtocol.vlessReality;
        _serverId ??= 'armenia-1';
      }
      _connectedAt ??= DateTime.now();
    } else if (phase == VpnConnectionPhase.disconnected) {
      _connectedAt = null;
      _serverId = null;
      _protocol = null;
    }
    _state = VpnConnectionState(
      phase: phase,
      serverId: phase == VpnConnectionPhase.disconnected ? null : _serverId,
      protocol: phase == VpnConnectionPhase.disconnected ? null : _protocol,
      connectedAt: phase == VpnConnectionPhase.connected ? _connectedAt : null,
      killSwitchActive: response.killSwitchActive,
      errorCode: phase.isFailure ? response.code : null,
    );
    _states.add(_state);
  }

  void _emit(VpnConnectionPhase phase) {
    _state = VpnConnectionState(
      phase: phase,
      serverId: _serverId,
      protocol: _protocol,
      connectedAt: phase == VpnConnectionPhase.connected ? _connectedAt : null,
      killSwitchActive: _state.killSwitchActive,
    );
    _states.add(_state);
  }

  void _emitFailure(String code) {
    final VpnConnectionPhase phase = switch (code) {
      'NO_NETWORK' => VpnConnectionPhase.noNetwork,
      'SERVER_UNAVAILABLE' => VpnConnectionPhase.serverUnavailable,
      'SUBSCRIPTION_REQUIRED' ||
      'PROFILE_NOT_FOUND' => VpnConnectionPhase.blockedBySubscription,
      _ => VpnConnectionPhase.error,
    };
    _state = VpnConnectionState(
      phase: phase,
      serverId: _serverId,
      protocol: _protocol,
      errorCode: code,
      killSwitchActive: _state.killSwitchActive,
    );
    _states.add(_state);
  }

  String _identifier(String prefix) {
    final StringBuffer value = StringBuffer('$prefix-');
    for (var index = 0; index < 16; index += 1) {
      value.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return value.toString();
  }

  static Uint8List _identifierBytes(String value) {
    if (!_validIdentifier(value)) {
      throw const ProfileProvisioningException('INVALID_IDENTIFIER');
    }
    return Uint8List.fromList(<int>[value.length, ...value.codeUnits]);
  }

  static bool _validIdentifier(String value) =>
      value.isNotEmpty &&
      value.length <= 64 &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

  static VpnConnectionPhase _phase(int value) => switch (value) {
    0 => VpnConnectionPhase.disconnected,
    1 => VpnConnectionPhase.validating,
    2 => VpnConnectionPhase.connecting,
    3 => VpnConnectionPhase.connected,
    4 => VpnConnectionPhase.reconnecting,
    5 => VpnConnectionPhase.disconnecting,
    6 => VpnConnectionPhase.blockedBySubscription,
    7 => VpnConnectionPhase.noNetwork,
    8 => VpnConnectionPhase.serverUnavailable,
    9 => VpnConnectionPhase.error,
    _ => throw const ProfileProvisioningException('INVALID_RESPONSE'),
  };

  static VpnStatistics _emptyStatistics() =>
      VpnStatistics(bytesReceived: 0, bytesSent: 0, measuredAt: DateTime.now());
}

final class _AccountAccess {
  const _AccountAccess({
    required this.active,
    this.profileHandle,
    this.amneziaWgProfileHandle,
    this.vlessProfileHandle,
    this.netherlandsVlessProfileHandle,
    this.netherlandsAmneziaWgProfileHandle,
  });

  final bool active;
  final String? profileHandle;
  final String? amneziaWgProfileHandle;
  final String? vlessProfileHandle;
  final String? netherlandsVlessProfileHandle;
  final String? netherlandsAmneziaWgProfileHandle;
}
