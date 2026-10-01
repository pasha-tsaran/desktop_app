import 'package:kenai_core/kenai_core.dart';
import 'desktop_platform.dart';

/// A setting is published only after Windows accepted it. Failed persistence
/// rolls back the native preference to keep the switch and OS in agreement.
final class SystemSettingsRepository implements SettingsRepository {
  SystemSettingsRepository(this.storage, this.platform, this.engine);
  final SettingsRepository storage;
  final DesktopPlatform platform;
  final SystemVpnEngine engine;
  @override
  Stream<AppSettings> get changes => storage.changes;
  @override
  Future<AppSettings> load() => storage.load();
  Future<void> _queue = Future<void>.value();
  @override
  Future<void> save(AppSettings value) {
    final result = _queue.then((_) => _save(value));
    _queue = result.catchError((Object _) {});
    return result;
  }

  Future<void> _save(AppSettings value) async {
    final previous = await load();
    final startupChanged = value.launchAtLogin != previous.launchAtLogin;
    final protectionChanged = value.killSwitch != previous.killSwitch;
    final trayChanged = value.trayEnabled != previous.trayEnabled;
    bool startupApplied = false;
    bool protectionApplied = false;
    bool trayApplied = false;
    try {
      if (startupChanged) {
        await platform.setLaunchAtLogin(value.launchAtLogin);
        startupApplied = true;
      }
      if (protectionChanged) {
        await engine.configureKillSwitch(value.killSwitch);
        protectionApplied = true;
      }
      if (trayChanged) {
        await platform.setTrayEnabled(value.trayEnabled);
        trayApplied = true;
      }
      await storage.save(value);
    } on Object {
      if (trayApplied) await platform.setTrayEnabled(previous.trayEnabled);
      if (startupApplied)
        await platform.setLaunchAtLogin(previous.launchAtLogin);
      if (protectionApplied)
        await engine.configureKillSwitch(previous.killSwitch);
      rethrow;
    }
  }
}
