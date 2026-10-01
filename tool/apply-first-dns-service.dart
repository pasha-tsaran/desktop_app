// One-off operator migration. Holds only the existing opaque handle in memory;
// never reads a profile or secret, and uses the shared typed IPC codec.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:kenai_vpn_desktop/src/infrastructure/windows_profile_provisioner.dart';

List<int> identifier(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(value)) {
    throw StateError('INVALID_IDENTIFIER');
  }
  return [value.length, ...value.codeUnits];
}

Future<VpnIpcResponse> exchange(int opcode, List<int> extra) async {
  final id = 'dns-update-${DateTime.now().microsecondsSinceEpoch}';
  final response = await const WindowsNamedPipeProfileTransport(
    timeout: Duration(seconds: 60),
  ).exchange(encodeVpnIpcFrame(
      opcode, Uint8List.fromList([...identifier(id), ...extra])));
  return decodeVpnIpcResponse(response, id);
}

Future<int> install({bool rollback = false}) async {
  final script =
      File.fromUri(Platform.script.resolve('apply-first-dns-service.ps1'))
          .absolute
          .path;
  final argument =
      '-NoProfile -ExecutionPolicy Bypass -File "$script"${rollback ? ' -Rollback' : ''}';
  final command =
      '\$p=Start-Process -FilePath "\$env:SystemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -Verb RunAs -WindowStyle Hidden -ArgumentList \'${argument.replaceAll("'", "''")}\' -PassThru -Wait; exit \$p.ExitCode';
  final bytes = <int>[];
  for (final unit in command.codeUnits) {
    bytes.addAll([unit & 255, unit >> 8]);
  }
  final result = await Process.run(
      'powershell.exe', ['-NoProfile', '-EncodedCommand', base64Encode(bytes)]);
  return result.exitCode;
}

Future<bool> connect(String handle) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      final state = await exchange(1, []);
      if (state.phase == 3 && state.profileId == handle) return true;
      final result = await exchange(2, [
        ...identifier('reconnect-${DateTime.now().microsecondsSinceEpoch}'),
        ...identifier(handle),
        3,
        0,
      ]);
      stdout.writeln('CONNECT_CODE=${result.code} PHASE=${result.phase}');
      return result.phase == 3;
    } on ProfileProvisioningException {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
  return false;
}

Future<bool> healthy() async {
  for (final url in [
    'https://api.ipify.org',
    'https://www.cloudflare.com/cdn-cgi/trace'
  ]) {
    final result = await Process.run('curl.exe', [
      '-q',
      '--noproxy',
      '*',
      '-4',
      '--silent',
      '--connect-timeout',
      '4',
      '--max-time',
      '8',
      url
    ]);
    stdout.writeln('HTTP_CHECK_EXIT=${result.exitCode}');
    final body = (result.stdout as String).trim();
    if (result.exitCode == 0 &&
        (body == '88.218.94.3' ||
            body.split('\n').any((line) => line.trim() == 'ip=88.218.94.3')))
      return true;
  }
  return false;
}

Future<void> main(List<String> args) async {
  var mutationStarted = false;
  String? handle;
  try {
    final before = await exchange(1, []);
    handle = before.profileId;
    if (before.phase != 3 ||
        before.killSwitchActive ||
        handle == null ||
        !handle.startsWith('xray-')) {
      stdout.writeln('RESULT=PRECONDITION_FAILED_NO_CHANGES');
      exitCode = 1;
      return;
    }
    if (!await healthy()) {
      stdout.writeln('RESULT=BASELINE_FAILED_NO_CHANGES');
      exitCode = 1;
      return;
    }
    stdout.writeln('PRECHECK=True');
    if (!args.contains('--apply')) return;
    mutationStarted = true;
    final installed = await install();
    stdout.writeln('INSTALL_EXIT=$installed');
    if (installed != 0 || !await connect(handle) || !await healthy())
      throw StateError('POSTCHECK_FAILED');
    stdout.writeln('RESULT=UPDATED_AND_RECONNECTED');
  } on Object {
    if (mutationStarted && handle != null) {
      final rolledBack = await install(rollback: true);
      final recovered =
          rolledBack == 0 && await connect(handle) && await healthy();
      stdout.writeln('ROLLBACK_EXIT=$rolledBack RECOVERED=$recovered');
    }
    stdout.writeln('RESULT=UPDATE_NOT_COMPLETED');
    exitCode = 1;
  }
}
