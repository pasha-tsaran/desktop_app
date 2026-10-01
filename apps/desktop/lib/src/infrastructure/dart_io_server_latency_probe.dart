import 'dart:async';
import 'dart:io';

import 'package:kenai_core/kenai_core.dart';

/// Measures the TCP handshake time to the production server without invoking
/// a shell command or requiring elevated ICMP permissions.
final class DartIoServerLatencyProbe implements ServerLatencyProbe {
  const DartIoServerLatencyProbe({
    required this.host,
    required this.port,
    this.timeout = const Duration(seconds: 3),
  });

  final String host;
  final int port;
  final Duration timeout;

  @override
  Future<Duration?> measure() async {
    final Stopwatch stopwatch = Stopwatch()..start();
    try {
      final Socket socket = await Socket.connect(host, port, timeout: timeout);
      stopwatch.stop();
      socket.destroy();
      final int milliseconds = stopwatch.elapsedMilliseconds;
      return Duration(milliseconds: milliseconds < 1 ? 1 : milliseconds);
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    }
  }
}
