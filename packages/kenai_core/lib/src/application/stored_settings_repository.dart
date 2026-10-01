import 'dart:async';
import 'dart:convert';

import '../domain/models.dart';
import '../ports/ports.dart';

final class StoredSettingsRepository implements SettingsRepository {
  StoredSettingsRepository({required SecureStorage secureStorage})
      : _secureStorage = secureStorage;

  static const String _storageKey = 'app.settings';

  final SecureStorage _secureStorage;
  final StreamController<AppSettings> _controller =
      StreamController<AppSettings>.broadcast(sync: true);

  @override
  Stream<AppSettings> get changes => _controller.stream;

  @override
  Future<AppSettings> load() async {
    final String? encoded = await _secureStorage.read(_storageKey);
    if (encoded == null) return const AppSettings.defaults();
    try {
      final Map<String, Object?> data =
          jsonDecode(encoded) as Map<String, Object?>;
      return AppSettings(
        theme: ThemePreference.values.byName(data['theme']! as String),
        locale: data['locale']! as String,
        protocol: ProtocolPreference.values.byName(data['protocol']! as String),
        dns: DnsPreference.values.byName(data['dns']! as String),
        autoConnect:
            AutoConnectMode.values.byName(data['auto_connect']! as String),
        defaultServerId: data['default_server_id'] as String?,
        killSwitch: data['kill_switch']! as bool,
        reconnectOnNetworkChange: data['reconnect_on_network_change']! as bool,
        sleepBehavior:
            SleepBehavior.values.byName(data['sleep_behavior']! as String),
        launchAtLogin: data['launch_at_login']! as bool,
        minimizeAfterConnect: data['minimize_after_connect']! as bool,
        autoUpdate: data['auto_update'] as bool? ?? false,
        trayEnabled: data['tray_enabled'] as bool? ?? false,
        sendDiagnostics: data['send_diagnostics']! as bool,
      );
    } on Object {
      await _secureStorage.delete(_storageKey);
      return const AppSettings.defaults();
    }
  }

  @override
  Future<void> save(AppSettings settings) async {
    await _secureStorage.write(
      key: _storageKey,
      value: jsonEncode(<String, Object?>{
        'theme': settings.theme.name,
        'locale': settings.locale,
        'protocol': settings.protocol.name,
        'dns': settings.dns.name,
        'auto_connect': settings.autoConnect.name,
        'default_server_id': settings.defaultServerId,
        'kill_switch': settings.killSwitch,
        'reconnect_on_network_change': settings.reconnectOnNetworkChange,
        'sleep_behavior': settings.sleepBehavior.name,
        'launch_at_login': settings.launchAtLogin,
        'minimize_after_connect': settings.minimizeAfterConnect,
        'auto_update': settings.autoUpdate,
        'tray_enabled': settings.trayEnabled,
        'send_diagnostics': settings.sendDiagnostics,
      }),
    );
    _controller.add(settings);
  }

  Future<void> dispose() => _controller.close();
}
