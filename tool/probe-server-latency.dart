import 'dart:io';

import 'package:kenai_vpn_desktop/src/infrastructure/dart_io_server_latency_probe.dart';

/// Manual read-only network check using the same adapter as the release UI.
Future<void> main() async {
  const probe = DartIoServerLatencyProbe(host: '88.218.94.3', port: 9443);
  for (var attempt = 0; attempt < 3; attempt++) {
    final latency = await probe.measure();
    stdout.writeln(latency == null
        ? 'TCP: unavailable'
        : 'TCP: ${latency.inMilliseconds} ms');
  }
}
