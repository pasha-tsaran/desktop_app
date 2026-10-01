import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_vpn_desktop/src/infrastructure/desktop_platform.dart';
import 'package:kenai_vpn_desktop/src/infrastructure/system_settings_repository.dart';
import 'package:kenai_vpn_desktop/src/vpn_automation.dart';

void main() {
  test(
      'cancel reaches a pending engine immediately and stops automatic fallback',
      () async {
    final f = await _fixture(const AppSettings.defaults());
    f.engine.connectGate = Completer<void>();
    f.engine.failVless = true;
    final attempt =
        f.automation.connect((await f.servers.getSelectedServer())!);
    await f.engine.started.future;
    await f.automation.disconnect();
    expect(f.engine.cancelled, isTrue);
    f.engine.connectGate!.complete();
    await attempt;
    expect(f.engine.requests, hasLength(1));
    expect(f.engine.state.phase, VpnConnectionPhase.disconnected);
  });
  test('unavailable tray never prevents automatic VPN connection', () async {
    final f = await _fixture(const AppSettings.defaults().copyWith(
        trayEnabled: true, autoConnect: AutoConnectMode.selectedServer));
    f.platform.failTray = true;
    await f.automation.start();
    expect(f.engine.requests, hasLength(1));
    expect(f.engine.state.phase, VpnConnectionPhase.connected);
  });

  test('unavailable tray does not save a successful toggle', () async {
    final storage = MockSettingsRepository();
    final platform = _Platform()..failTray = true;
    final engine = _Engine();
    final settings = SystemSettingsRepository(storage, platform, engine);
    await expectLater(
        settings.save(const AppSettings.defaults().copyWith(trayEnabled: true)),
        throwsStateError);
    expect((await settings.load()).trayEnabled, isFalse);
    expect(engine.requests, isEmpty);
    await storage.dispose();
    await platform.dispose();
    await engine.controller.close();
  });

  test('tray preference is restored at startup without connecting VPN',
      () async {
    final f = await _fixture(
        const AppSettings.defaults().copyWith(trayEnabled: true));
    await f.automation.start();
    expect(f.platform.tray, isTrue);
    expect(f.engine.requests, isEmpty);
  });

  test('tray setting reaches native adapter and persists after success',
      () async {
    final storage = MockSettingsRepository();
    final platform = _Platform();
    final engine = _Engine();
    final settings = SystemSettingsRepository(storage, platform, engine);
    await settings
        .save(const AppSettings.defaults().copyWith(trayEnabled: true));
    expect(platform.tray, isTrue);
    expect((await settings.load()).trayEnabled, isTrue);
    expect(engine.requests, isEmpty);
    await settings.save(const AppSettings.defaults());
    expect(platform.tray, isFalse);
    await storage.dispose();
    await platform.dispose();
    await engine.controller.close();
  });
  test('startup alone never establishes a VPN tunnel', () async {
    final f = await _fixture(
        const AppSettings.defaults().copyWith(launchAtLogin: true));
    await f.automation.start();
    expect(f.platform.startup, isTrue);
    expect(f.engine.requests, isEmpty);
  });

  for (final enabled in [true, false]) {
    test('network recovery follows setting $enabled', () async {
      final f = await _fixture(const AppSettings.defaults()
          .copyWith(reconnectOnNetworkChange: enabled));
      await f.automation.start();
      await f.automation.connect((await f.servers.getSelectedServer())!);
      f.platform.controller.add(DesktopEvent.networkChanged);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(f.engine.requests, hasLength(enabled ? 2 : 1));
    });
  }

  test(
      'failed native setting is not saved and does not disable existing protection',
      () async {
    final storage = MockSettingsRepository();
    final platform = _Platform();
    final engine = _Engine()..protected = true;
    engine.failProtection = true;
    final settings = SystemSettingsRepository(storage, platform, engine);
    await expectLater(
        settings.save(const AppSettings.defaults()
            .copyWith(killSwitch: true, launchAtLogin: true)),
        throwsStateError);
    expect((await settings.load()).killSwitch, isFalse);
    expect((await settings.load()).launchAtLogin, isFalse);
    expect(platform.startup, isFalse);
    expect(engine.protected, isTrue);
    await storage.dispose();
    await platform.dispose();
    await engine.controller.close();
  });

  test('automatic mode falls back from VLESS to AWG with protection preserved',
      () async {
    final f =
        await _fixture(const AppSettings.defaults().copyWith(killSwitch: true));
    f.engine.failVless = true;
    await f.automation.start();
    await f.automation.connect((await f.servers.getSelectedServer())!);
    expect(f.engine.requests.map((r) => r.profile.protocol),
        [VpnProtocol.vlessReality, VpnProtocol.amneziaWg]);
    expect(f.engine.requests.every((r) => r.killSwitch), isTrue);
    expect(f.engine.state.phase, VpnConnectionPhase.connected);
    await f.automation.disconnect();
    expect(f.engine.protected, isTrue);
  });

  test('startup connects to configured server and minimizes only after success',
      () async {
    final f = await _fixture(const AppSettings.defaults().copyWith(
        defaultServerId: 'armenia-1',
        protocol: ProtocolPreference.amneziaWg,
        autoConnect: AutoConnectMode.selectedServer,
        launchAtLogin: true,
        minimizeAfterConnect: true));
    await f.automation.start();
    await Future<void>.delayed(Duration.zero);
    expect(f.engine.requests.single.profile.serverId, 'armenia-1');
    expect(f.engine.requests.single.profile.protocol, VpnProtocol.amneziaWg);
    expect(f.platform.startup, isTrue);
    expect(f.platform.minimized, 1);
    await f.engine.status();
    expect(f.platform.minimized, 1);
  });

  test('manual disconnect cancels network recovery', () async {
    final f = await _fixture(
        const AppSettings.defaults().copyWith(reconnectOnNetworkChange: true));
    await f.automation.start();
    await f.automation.connect((await f.servers.getSelectedServer())!);
    f.platform.controller.add(DesktopEvent.networkChanged);
    await f.automation.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(f.engine.requests, hasLength(1));
    expect(f.engine.state.phase, VpnConnectionPhase.disconnected);
  });

  for (final behavior in SleepBehavior.values) {
    test(
        'sleep policy ${behavior.name} survives simultaneous network notifications',
        () async {
      final f = await _fixture(const AppSettings.defaults()
          .copyWith(sleepBehavior: behavior, reconnectOnNetworkChange: true));
      await f.automation.start();
      await f.automation.connect((await f.servers.getSelectedServer())!);
      f.platform.controller.add(DesktopEvent.suspend);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(f.engine.state.phase, VpnConnectionPhase.disconnected);
      f.platform.controller.add(DesktopEvent.resume);
      f.platform.controller.add(DesktopEvent.networkChanged);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(f.engine.requests,
          hasLength(behavior == SleepBehavior.reconnect ? 2 : 1));
    });
  }

  test('explicit protocol never silently falls back', () async {
    final f = await _fixture(const AppSettings.defaults()
        .copyWith(protocol: ProtocolPreference.vlessReality));
    f.engine.failVless = true;
    await f.automation.start();
    await f.automation.connect((await f.servers.getSelectedServer())!);
    expect(f.engine.requests, hasLength(1));
  });
}

Future<
    ({
      VpnAutomation automation,
      _Engine engine,
      _Platform platform,
      ServerRepository servers
    })> _fixture(AppSettings config) async {
  final engine = _Engine();
  final platform = _Platform();
  final servers = ArmeniaMvpServerRepository();
  final settings = MockSettingsRepository(initialSettings: config);
  final account = SecureAccountRepository(
      apiClient: MockActivationApiClient(),
      secureStorage: InMemorySecureStorage());
  await account.activate(ActivationKey.parse('123456789012'));
  final automation = VpnAutomation(
      engine: engine,
      servers: servers,
      settings: settings,
      account: account,
      platform: platform,
      recoveryDelay: const Duration(milliseconds: 1));
  addTearDown(() async {
    await automation.dispose();
    await settings.dispose();
    await engine.controller.close();
  });
  return (
    automation: automation,
    engine: engine,
    platform: platform,
    servers: servers
  );
}

final class _Platform implements DesktopPlatform {
  final controller = StreamController<DesktopEvent>.broadcast(sync: true);
  bool startup = false;
  bool tray = false;
  bool failTray = false;
  int minimized = 0;
  @override
  Stream<DesktopEvent> get events => controller.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> setTrayEnabled(bool enabled) async {
    if (failTray) throw StateError('Explorer unavailable');
    tray = enabled;
  }

  @override
  Future<void> setLaunchAtLogin(bool enabled) async {
    startup = enabled;
  }

  @override
  Future<void> minimize() async {
    minimized++;
  }

  @override
  Future<void> dispose() => controller.close();
}

final class _Engine
    implements VpnEngine, SystemVpnEngine, CancellableVpnEngine {
  Completer<void>? connectGate;
  final started = Completer<void>();
  bool cancelled = false;
  final controller = StreamController<VpnConnectionState>.broadcast(sync: true);
  final requests = <ConnectionRequest>[];
  var state = const VpnConnectionState.disconnected();
  bool protected = false;
  bool failVless = false;
  bool failProtection = false;
  @override
  Stream<VpnConnectionState> get states => controller.stream;
  @override
  Set<VpnProtocol> get supportedProtocols =>
      {VpnProtocol.vlessReality, VpnProtocol.amneziaWg};
  @override
  Future<void> configureKillSwitch(bool enabled) async {
    if (failProtection) throw StateError('Native protection unavailable');
    protected = enabled;
  }

  @override
  Future<void> connect(ConnectionRequest request) async {
    requests.add(request);
    if (!started.isCompleted) started.complete();
    if (connectGate != null) await connectGate!.future;
    state = VpnConnectionState(
        phase: failVless && request.profile.protocol == VpnProtocol.vlessReality
            ? VpnConnectionPhase.serverUnavailable
            : VpnConnectionPhase.connected,
        protocol: request.profile.protocol,
        serverId: request.profile.serverId,
        killSwitchActive: protected);
    controller.add(state);
  }

  @override
  Future<void> cancelConnection({required String operationId}) {
    cancelled = true;
    return disconnect(operationId: operationId);
  }

  @override
  Future<void> disconnect({required String operationId}) async {
    state = VpnConnectionState(
        phase: VpnConnectionPhase.disconnected, killSwitchActive: protected);
    controller.add(state);
  }

  @override
  Future<VpnConnectionState> status() async => state;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
