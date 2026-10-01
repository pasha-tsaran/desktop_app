import 'dart:io';
import 'dart:typed_data';

import 'package:kenai_vpn_desktop/src/infrastructure/windows_profile_provisioner.dart';

// Manual, non-secret diagnostic for the local Kenai Windows service only.
// Sends only the read-only Status command; never reads VPN credentials.
Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    stdout.writeln('windows_only');
    return;
  }
  final int attempts = arguments.contains('--stress') ? 100 : 3;
  for (var attempt = 1; attempt <= attempts; attempt += 1) {
    final String requestId =
        'probe-${DateTime.now().microsecondsSinceEpoch}-$attempt';
    final Uint8List request = encodeVpnIpcFrame(
      1,
      Uint8List.fromList(<int>[requestId.length, ...requestId.codeUnits]),
    );
    try {
      final Uint8List response = await const WindowsNamedPipeProfileTransport(
        timeout: Duration(seconds: 5),
      ).exchange(request);
      final result = decodeVpnIpcResponse(response, requestId);
      final String code = result.code;
      stdout.writeln('status_$attempt:$code');
      if (arguments.contains('--details')) {
        stdout.writeln(
            'phase:${result.phase};kill_switch:${result.killSwitchActive}');
      }
      if (code != 'OK') {
        exitCode = 1;
        break;
      }
    } on ProfileProvisioningException catch (error) {
      stdout.writeln('status_$attempt:${error.code}');
      exitCode = 1;
      break;
    }
  }
}
