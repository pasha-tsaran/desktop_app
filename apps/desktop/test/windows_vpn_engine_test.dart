import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_vpn_desktop/src/infrastructure/windows_profile_provisioner.dart';
import 'package:kenai_vpn_desktop/src/infrastructure/windows_vpn_engine.dart';

void main() {
  for (final protocol in [VpnProtocol.amneziaWg, VpnProtocol.vlessReality]) {
    test('cancels pending $protocol without applying late success', () async {
      final storage = InMemorySecureStorage();
      await _activateStorage(storage);
      await storage.write(
          key: SecureAccountStorageKeys.amneziaWgProfileHandle,
          value: _VpnTransport.awgProfileHandle);
      await storage.write(
          key: SecureAccountStorageKeys.vlessProfileHandle,
          value: _VpnTransport.xrayProfileHandle);
      final transport = _DelayedTransport();
      final engine =
          WindowsVpnEngine(secureStorage: storage, transport: transport);
      final phases = <VpnConnectionPhase>[];
      final subscription =
          engine.states.listen((state) => phases.add(state.phase));
      final connect = engine.connect(ConnectionRequest(
          operationId: 'pending-connect',
          profile: VpnProfile(
              id: 'test',
              deviceId: 'test',
              serverId: 'armenia-1',
              protocol: protocol),
          killSwitch: true));
      await transport.started.future;
      final cancel = engine.cancelConnection(operationId: 'cancel');
      final duplicate = engine.disconnect(operationId: 'duplicate');
      await Future.wait([cancel, duplicate]);
      expect(transport.opcodes, [2, 3]);
      expect(transport.disconnectOperation, 'pending-connect');
      transport.completeConnect();
      await connect;
      expect(phases, isNot(contains(VpnConnectionPhase.connected)));
      expect((await engine.status()).phase, VpnConnectionPhase.disconnected);
      expect((await engine.status()).killSwitchActive, isTrue);
      await subscription.cancel();
    });
  }
  late InMemorySecureStorage storage;
  late _VpnTransport transport;
  late WindowsVpnEngine engine;

  setUp(() {
    storage = InMemorySecureStorage();
    transport = _VpnTransport();
    engine = WindowsVpnEngine(
      secureStorage: storage,
      transport: transport,
      random: Random(1),
    );
  });

  test('requires an activated 12-digit account before service access',
      () async {
    final List<VpnConnectionState> states = <VpnConnectionState>[];
    final subscription = engine.states.listen(states.add);

    await engine.connect(_request());

    expect(states.map((state) => state.phase), <VpnConnectionPhase>[
      VpnConnectionPhase.validating,
      VpnConnectionPhase.blockedBySubscription,
    ]);
    expect(states.last.errorCode, 'SUBSCRIPTION_REQUIRED');
    expect(transport.opcodes, isEmpty);
    await subscription.cancel();
  });

  test('connects by opaque profile handle and never sends activation key',
      () async {
    await _activateStorage(storage);
    final List<VpnConnectionState> states = <VpnConnectionState>[];
    final subscription = engine.states.listen(states.add);

    await engine.connect(_request());

    expect(transport.opcodes, <int>[2]);
    expect(states.map((state) => state.phase), <VpnConnectionPhase>[
      VpnConnectionPhase.validating,
      VpnConnectionPhase.connecting,
      VpnConnectionPhase.connected,
    ]);
    expect(
      String.fromCharCodes(transport.lastRequest),
      contains(_VpnTransport.profileHandle),
    );
    expect(String.fromCharCodes(transport.lastRequest), isNot(contains(_key)));
    expect((await engine.status()).phase, VpnConnectionPhase.connected);
    await subscription.cancel();
  });

  test('reports service counters and disconnects through typed IPC', () async {
    await _activateStorage(storage);
    await engine.connect(_request());

    final VpnStatistics statistics = await engine.statistics();
    expect(statistics.bytesReceived, 200);
    expect(statistics.bytesSent, 100);

    await engine.disconnect(operationId: 'disconnect-1');
    expect(transport.opcodes, <int>[2, 7, 3]);
    expect((await engine.status()).phase, VpnConnectionPhase.disconnected);
  });

  test('typed protection command survives disconnect until explicitly disabled',
      () async {
    await engine.configureKillSwitch(true);
    expect(transport.lastRequest.last, 1);
    expect((await engine.status()).killSwitchActive, isTrue);
    await engine.disconnect(operationId: 'manual');
    expect((await engine.status()).killSwitchActive, isTrue);
    await engine.configureKillSwitch(false);
    expect(transport.lastRequest.last, 0);
    expect((await engine.status()).killSwitchActive, isFalse);
    expect(transport.opcodes.where((value) => value == 10), hasLength(2));
  });

  test('exposes service protection and hides unsupported DNS override', () {
    expect(engine.supportedProtocols, <VpnProtocol>{
      VpnProtocol.wireGuard,
      VpnProtocol.amneziaWg,
      VpnProtocol.vlessReality,
    });
    expect(
      engine.capabilitiesFor(VpnProtocol.wireGuard).supportsKillSwitch,
      isTrue,
    );
    expect(
      engine.capabilitiesFor(VpnProtocol.amneziaWg).supportsDns,
      isFalse,
    );
  });

  test('connects AmneziaWG with its separate opaque handle and protocol',
      () async {
    await _activateStorage(storage);
    await storage.write(
      key: SecureAccountStorageKeys.amneziaWgProfileHandle,
      value: _VpnTransport.awgProfileHandle,
    );
    await engine.connect(const ConnectionRequest(
      operationId: 'connect-awg',
      profile: VpnProfile(
        id: 'ui-awg',
        deviceId: 'windows-device',
        serverId: 'armenia-1',
        protocol: VpnProtocol.amneziaWg,
      ),
      killSwitch: false,
    ));
    expect(transport.lastRequest,
        containsAllInOrder(_VpnTransport.awgProfileHandle.codeUnits));
    expect(transport.lastRequest.last, 0);
    expect(transport.lastRequest[transport.lastRequest.length - 2], 2);
  });

  test('connects VLESS with its separate Xray handle and protocol', () async {
    await _activateStorage(storage);
    await storage.write(
      key: SecureAccountStorageKeys.vlessProfileHandle,
      value: _VpnTransport.xrayProfileHandle,
    );
    await engine.connect(const ConnectionRequest(
      operationId: 'connect-xray',
      profile: VpnProfile(
        id: 'ui-xray',
        deviceId: 'windows-device',
        serverId: 'armenia-1',
        protocol: VpnProtocol.vlessReality,
      ),
      killSwitch: false,
    ));
    expect(transport.lastRequest,
        containsAllInOrder(_VpnTransport.xrayProfileHandle.codeUnits));
    expect(transport.lastRequest.last, 0);
    expect(transport.lastRequest[transport.lastRequest.length - 2], 3);
  });

  test('Netherlands selection uses its own opaque handle', () async {
    await _activateStorage(storage);
    await storage.write(
      key: SecureAccountStorageKeys.vlessProfileHandle,
      value: 'xray-armenia-handle',
    );
    await storage.write(
      key: SecureAccountStorageKeys.netherlandsVlessProfileHandle,
      value: _VpnTransport.xrayProfileHandle,
    );
    await engine.connect(const ConnectionRequest(
      operationId: 'connect-netherlands',
      profile: VpnProfile(
        id: 'ui-netherlands',
        deviceId: 'windows-device',
        serverId: 'netherlands-1',
        protocol: VpnProtocol.vlessReality,
      ),
      killSwitch: false,
    ));
    expect(transport.lastRequest,
        containsAllInOrder(_VpnTransport.xrayProfileHandle.codeUnits));
    expect(transport.lastRequest,
        isNot(containsAllInOrder('xray-armenia-handle'.codeUnits)));
  });
}

const String _key = '123456789012';

final class _DelayedTransport implements ProfileIpcTransport {
  final started = Completer<void>();
  final pending = Completer<Uint8List>();
  final opcodes = <int>[];
  List<int> connectId = [];
  String? disconnectOperation;
  @override
  Future<Uint8List> exchange(Uint8List request) async {
    final opcode = request[6];
    opcodes.add(opcode);
    final length = request[12];
    final id = request.sublist(13, 13 + length);
    if (opcode == 2) {
      connectId = id;
      started.complete();
      return pending.future;
    }
    if (opcode == 3) {
      final offset = 13 + length;
      disconnectOperation = String.fromCharCodes(
          request.sublist(offset + 1, offset + 1 + request[offset]));
    }
    return _VpnTransport._response(id,
        phase: 0, code: 'DISCONNECTED', statistics: false, protected: true);
  }

  void completeConnect() => pending.complete(_VpnTransport._response(connectId,
      phase: 3, code: 'CONNECTED', statistics: false, protected: true));
}

Future<void> _activateStorage(InMemorySecureStorage storage) async {
  await storage.write(
    key: SecureAccountStorageKeys.activationKey,
    value: _key,
  );
  await storage.write(
    key: SecureAccountStorageKeys.session,
    value: jsonEncode(<String, Object?>{
      'subscription': <String, Object?>{'status': 'active'},
    }),
  );
  await storage.write(
    key: SecureAccountStorageKeys.profileHandle,
    value: _VpnTransport.profileHandle,
  );
}

ConnectionRequest _request() => const ConnectionRequest(
      operationId: 'connect-1',
      profile: VpnProfile(
        id: 'ui-profile',
        deviceId: 'windows-device',
        serverId: 'armenia-1',
        protocol: VpnProtocol.wireGuard,
      ),
      killSwitch: false,
    );

final class _VpnTransport implements ProfileIpcTransport {
  static const String profileHandle = 'wg-00112233445566778899aabbccddeeff';
  static const String awgProfileHandle = 'awg-00112233445566778899aabbccddeeff';
  static const String xrayProfileHandle =
      'xray-00112233445566778899aabbccddeeff';
  final List<int> opcodes = <int>[];
  Uint8List lastRequest = Uint8List(0);
  bool connected = false;
  bool protected = false;

  @override
  Future<Uint8List> exchange(Uint8List request) async {
    lastRequest = request;
    final int opcode = request[6];
    opcodes.add(opcode);
    if (opcode == 2) connected = true;
    if (opcode == 3) connected = false;
    if (opcode == 10) protected = request.last == 1;
    final int requestIdLength = request[12];
    final List<int> requestId = request.sublist(13, 13 + requestIdLength);
    final int phase = connected ? 3 : 0;
    return _response(
      requestId,
      phase: phase,
      code: opcode == 3 ? 'DISCONNECTED' : 'OK',
      statistics: opcode == 7,
      protected: protected,
    );
  }

  static Uint8List _response(
    List<int> requestId, {
    required int phase,
    required String code,
    required bool statistics,
    required bool protected,
  }) {
    final BytesBuilder body = BytesBuilder(copy: false)
      ..addByte(requestId.length)
      ..add(requestId)
      ..addByte(phase)
      ..addByte(0)
      ..addByte(protected ? 1 : 0)
      ..addByte(code.length)
      ..add(code.codeUnits)
      ..addByte(statistics ? 1 : 0);
    if (statistics) {
      final Uint8List counters = Uint8List(17);
      ByteData.sublistView(counters)
        ..setUint64(0, 200, Endian.little)
        ..setUint64(8, 100, Endian.little)
        ..setUint8(16, 0);
      body.add(counters);
    }
    return encodeVpnIpcFrame(0x81, body.takeBytes());
  }
}
