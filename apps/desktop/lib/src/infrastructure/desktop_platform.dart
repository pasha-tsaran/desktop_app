import 'dart:async';

import 'package:flutter/services.dart';

enum DesktopEvent { networkChanged, suspend, resume }

abstract interface class DesktopPlatform {
  Stream<DesktopEvent> get events;
  Future<void> setLaunchAtLogin(bool enabled);
  Future<void> setTrayEnabled(bool enabled);
  Future<void> minimize();
  Future<void> start();
  Future<void> dispose();
}

/// Fixed native operations; no shell or caller-selected command/path crosses
/// this channel. Native code derives the executable path itself.
final class WindowsDesktopPlatform implements DesktopPlatform {
  static const MethodChannel _channel = MethodChannel('kenai/system');
  final _events = StreamController<DesktopEvent>.broadcast();
  Timer? _timer;
  String? _network;
  bool _polling = false;
  bool _disposed = false;

  @override
  Stream<DesktopEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    if (_disposed) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'suspend') _events.add(DesktopEvent.suspend);
      if (call.method == 'resume') _events.add(DesktopEvent.resume);
    });
    await _poll();
    if (_disposed) return;
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_polling || _disposed) return;
    _polling = true;
    try {
      final value = await _channel.invokeMethod<String>('networkState');
      if (_disposed) return;
      if (value != null && _network != null && value != _network) {
        _events.add(DesktopEvent.networkChanged);
      }
      _network = value;
    } on PlatformException {
      // A failed read is not evidence of a network transition.
    } finally {
      _polling = false;
    }
  }

  @override
  Future<void> setLaunchAtLogin(bool enabled) =>
      _channel.invokeMethod<void>('launchAtLogin', enabled);

  @override
  Future<void> minimize() => _channel.invokeMethod<void>('minimize');

  @override
  Future<void> setTrayEnabled(bool enabled) =>
      _channel.invokeMethod<void>('trayEnabled', enabled);

  @override
  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    _channel.setMethodCallHandler(null);
    await _events.close();
  }
}
