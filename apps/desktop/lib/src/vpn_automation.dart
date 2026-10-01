import 'dart:async';

import 'package:kenai_core/kenai_core.dart';

import 'infrastructure/desktop_platform.dart';

/// One connection owner shared by every page. Automatic work is serialized
/// with manual work, and explicit disconnect invalidates queued recovery.
final class VpnAutomation {
  VpnAutomation({
    required this.engine,
    required this.servers,
    required this.settings,
    required this.account,
    required this.platform,
    this.recoveryDelay = const Duration(seconds: 3),
  });
  final Duration recoveryDelay;

  final VpnEngine engine;
  final ServerRepository servers;
  final SettingsRepository settings;
  final AccountRepository account;
  final DesktopPlatform platform;
  StreamSubscription<DesktopEvent>? _events;
  StreamSubscription<VpnConnectionState>? _states;
  Timer? _recovery;
  Timer? _statusTimer;
  bool _checkingStatus = false;
  bool _startupWaiting = false;
  Future<void> _queue = Future<void>.value();
  bool _wanted = false;
  bool _sleeping = false;
  bool _wantedBeforeSleep = false;
  bool _resuming = false;
  VpnConnectionPhase? _previousPhase;
  bool _disposed = false;
  int _generation = 0;
  VpnServer? _lastServer;
  VpnProtocol? _lastProtocol;

  Future<void> start() async {
    final config = await settings.load();
    final catalog = await servers.getServers();
    final selected =
        catalog.where((s) => s.id == config.defaultServerId).firstOrNull;
    if (selected != null) await servers.selectServer(selected.id);
    await platform.setLaunchAtLogin(config.launchAtLogin);
    try {
      await platform.setTrayEnabled(config.trayEnabled);
    } on Object {
      // Explorer can be unavailable during login. The native adapter never
      // hides a window without a registered icon. Tray failure must not stop
      // VPN protection, auto-connect or network/sleep subscriptions.
    }
    if (engine case final SystemVpnEngine system) {
      if (config.killSwitch) await system.configureKillSwitch(true);
    }
    if (_disposed) return;
    _events = platform.events.listen(_onEvent);
    _states = engine.states.listen((state) {
      if (state.phase == VpnConnectionPhase.connected &&
          _previousPhase != VpnConnectionPhase.connected) {
        _lastProtocol = state.protocol ?? _lastProtocol;
        unawaited(_minimizeIfRequested());
      }
      _previousPhase = state.phase;
    });
    await platform.start();
    if (_disposed) return;
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_checkingStatus || _disposed || _sleeping) return;
      _checkingStatus = true;
      try {
        await engine.status();
      } on Object {
        /* reported by engine */
      } finally {
        _checkingStatus = false;
      }
    });
    final state = await engine.status();
    if (state.phase == VpnConnectionPhase.connected) {
      _wanted = true;
      _lastServer = await servers.getSelectedServer();
      _lastProtocol = state.protocol;
      return;
    }
    if (config.autoConnect != AutoConnectMode.disabled &&
        await account.restoreSession() != null) {
      final target = config.autoConnect == AutoConnectMode.recommendedServer
          ? catalog
              .where((s) => s.isRecommended && s.canAttemptConnection)
              .firstOrNull
          : selected;
      final server =
          target ?? catalog.where((s) => s.canAttemptConnection).firstOrNull;
      if (server != null) {
        _startupWaiting = true;
        await connect(server);
      }
    }
  }

  Future<void> _minimizeIfRequested() async {
    try {
      if ((await settings.load()).minimizeAfterConnect)
        await platform.minimize();
    } on Object {
      /* Window failure must not tear down a working tunnel. */
    }
  }

  Future<void> _serialized(Future<void> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> connect(VpnServer server, {VpnProtocol? protocol}) {
    _resuming = false;
    _wanted = true;
    _lastServer = server;
    _lastProtocol = protocol;
    final generation = ++_generation;
    _recovery?.cancel();
    return _serialized(() => _connect(server, protocol, generation));
  }

  Future<void> _connect(
    VpnServer server,
    VpnProtocol? explicit,
    int generation,
  ) async {
    if (!_wanted || _disposed || _sleeping || generation != _generation) return;
    final config = await settings.load();
    final preferred = switch (config.protocol) {
      ProtocolPreference.wireGuard => VpnProtocol.wireGuard,
      ProtocolPreference.amneziaWg => VpnProtocol.amneziaWg,
      ProtocolPreference.vlessReality => VpnProtocol.vlessReality,
      ProtocolPreference.automatic => null,
    };
    final requested = explicit ?? preferred;
    final candidates = requested == null
        ? (server.id == 'netherlands-1'
            ? <VpnProtocol>[
                VpnProtocol.amneziaWg,
                VpnProtocol.vlessReality,
                VpnProtocol.wireGuard,
              ]
            : <VpnProtocol>[
                VpnProtocol.vlessReality,
                VpnProtocol.amneziaWg,
                VpnProtocol.wireGuard,
              ])
        : <VpnProtocol>[requested];
    final current = await engine.status();
    if (!_isCurrent(generation)) return;
    if (current.phase == VpnConnectionPhase.connected ||
        current.phase.isFailure) {
      await engine.disconnect(operationId: _id('prepare'));
    }
    await servers.selectServer(server.id);
    final available = candidates
        .where(
          (p) =>
              server.protocols.contains(p) &&
              engine.supportedProtocols.contains(p),
        )
        .toList();
    bool attempted = false;
    for (final protocol in available) {
      if (!_wanted || _disposed || _sleeping || generation != _generation)
        return;
      if (!await account.ensureProtocolProfile(protocol, serverId: server.id)) {
        continue;
      }
      if (!_isCurrent(generation)) return;
      if (attempted) await engine.disconnect(operationId: _id('fallback'));
      if (!_isCurrent(generation)) return;
      attempted = true;
      await engine.connect(
        ConnectionRequest(
          operationId: _id('connect'),
          profile: VpnProfile(
            id: 'profile-${server.id}-${protocol.name}',
            deviceId: 'local-windows-device',
            serverId: server.id,
            protocol: protocol,
          ),
          killSwitch: config.killSwitch,
        ),
      );
      final result = await engine.status();
      if (!_wanted || _sleeping || generation != _generation) {
        await engine.disconnect(operationId: _id('cancel'));
        return;
      }
      if (result.phase == VpnConnectionPhase.connected) {
        _startupWaiting = false;
        _lastProtocol = protocol;
        return;
      }
      if (result.phase == VpnConnectionPhase.blockedBySubscription &&
          result.errorCode != 'PROFILE_NOT_FOUND') return;
    }
    if (!attempted) throw StateError('No compatible VPN profile is available');
  }

  Future<void> disconnect() {
    _resuming = false;
    _wantedBeforeSleep = false;
    _startupWaiting = false;
    _wanted = false;
    ++_generation;
    _recovery?.cancel();
    if (engine case final CancellableVpnEngine cancellable) {
      final cancellation = cancellable.cancelConnection(
        operationId: _id('cancel'),
      );
      // Begin cancellation immediately, but keep future connects behind cleanup.
      final previous = _queue;
      _queue = Future.wait<void>([previous, cancellation])
          .then((_) {})
          .catchError((Object _) {});
      return cancellation;
    }
    return _serialized(() => engine.disconnect(operationId: _id('disconnect')));
  }

  bool _isCurrent(int generation) =>
      _wanted && !_disposed && !_sleeping && generation == _generation;

  void _onEvent(DesktopEvent event) {
    if (_disposed) return;
    if (event == DesktopEvent.suspend) {
      _wantedBeforeSleep = _wanted;
      _wanted = false;
      _sleeping = true;
      ++_generation;
      _recovery?.cancel();
      unawaited(
        _serialized(() async {
          await engine.disconnect(operationId: _id('sleep'));
        }).catchError((Object _) {}),
      );
      return;
    }
    if (event == DesktopEvent.resume) {
      if (!_sleeping) return;
      _sleeping = false;
      _resuming = true;
    } else if (_sleeping || _resuming) {
      return;
    }
    _recovery?.cancel();
    final generation = _generation;
    _recovery = Timer(recoveryDelay, () async {
      try {
        final config = await settings.load();
        if (generation != _generation || _disposed) return;
        if (event == DesktopEvent.resume) {
          _resuming = false;
          _wanted = _wantedBeforeSleep &&
              config.sleepBehavior == SleepBehavior.reconnect;
        }
        if (event == DesktopEvent.resume &&
            config.sleepBehavior == SleepBehavior.disconnect) {
          _wanted = false;
          return;
        }
        if (event == DesktopEvent.networkChanged &&
            !config.reconnectOnNetworkChange &&
            !_startupWaiting) return;
        final target = _lastServer;
        if (!_wanted ||
            _sleeping ||
            generation != _generation ||
            target == null) return;
        await _serialized(
          () => _connect(
            target,
            config.protocol == ProtocolPreference.automatic
                ? null
                : _lastProtocol,
            generation,
          ),
        );
      } on Object {
        /* The engine exposes failures through its state stream. */
      }
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    ++_generation;
    _recovery?.cancel();
    await _events?.cancel();
    _statusTimer?.cancel();
    await _states?.cancel();
    await platform.dispose();
  }

  static String _id(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}';
}
