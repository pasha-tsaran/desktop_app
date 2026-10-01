import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_vpn_desktop/src/infrastructure/dart_io_server_latency_probe.dart';

void main() {
  test('measures a real TCP handshake to the configured server', () async {
    final ServerSocket listener =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(listener.close);
    final subscription = listener.listen((Socket socket) => socket.destroy());
    addTearDown(subscription.cancel);

    final Duration? latency = await DartIoServerLatencyProbe(
      host: InternetAddress.loopbackIPv4.address,
      port: listener.port,
    ).measure();

    expect(latency, isNotNull);
    expect(latency!.inMilliseconds, greaterThanOrEqualTo(1));
  });

  test('returns null when the configured server is unreachable', () async {
    final ServerSocket listener =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final int closedPort = listener.port;
    await listener.close();

    final Duration? latency = await DartIoServerLatencyProbe(
      host: InternetAddress.loopbackIPv4.address,
      port: closedPort,
      timeout: const Duration(milliseconds: 100),
    ).measure();

    expect(latency, isNull);
  });
}
