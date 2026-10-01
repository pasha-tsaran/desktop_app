// One-off, rollback-safe acceptance update. It keeps only an opaque profile
// handle in memory and never reads or prints VPN credentials.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kenai_vpn_desktop/src/infrastructure/windows_profile_provisioner.dart';

List<int> _identifier(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(value)) {
    throw StateError('INVALID_IDENTIFIER');
  }
  return <int>[value.length, ...value.codeUnits];
}

Future<VpnIpcResponse> _exchange(int opcode, List<int> extra) async {
  final id = 'readiness-${DateTime.now().microsecondsSinceEpoch}';
  final response = await const WindowsNamedPipeProfileTransport(
    timeout: Duration(seconds: 60),
  ).exchange(encodeVpnIpcFrame(
    opcode,
    Uint8List.fromList(<int>[..._identifier(id), ...extra]),
  ));
  return decodeVpnIpcResponse(response, id);
}

Future<int> _install({bool rollback = false}) async {
  final script = File.fromUri(
    Platform.script.resolve('apply-armenia-readiness-service.ps1'),
  ).absolute.path;
  final argument = '-NoProfile -ExecutionPolicy Bypass -File "$script"'
      '${rollback ? ' -Rollback' : ''}';
  final command = r'$p=Start-Process -FilePath '
      r'"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" '
      r'-Verb RunAs -WindowStyle Hidden -ArgumentList '
      "'${argument.replaceAll("'", "''")}' -PassThru -Wait; exit \$p.ExitCode";
  final bytes = <int>[];
  for (final unit in command.codeUnits) {
    bytes.addAll(<int>[unit & 255, unit >> 8]);
  }
  final result = await Process.run(
    'powershell.exe',
    <String>['-NoProfile', '-EncodedCommand', base64Encode(bytes)],
  );
  return result.exitCode;
}

Future<int> _installPackage() async {
  final script = File.fromUri(
    Platform.script.resolve('apply-armenia-readiness-installer.ps1'),
  ).absolute.path;
  final argument = '-NoProfile -ExecutionPolicy Bypass -File "$script"';
  final command = r'$p=Start-Process -FilePath '
      r'"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" '
      r'-Verb RunAs -WindowStyle Hidden -ArgumentList '
      "'${argument.replaceAll("'", "''")}' -PassThru -Wait; exit \$p.ExitCode";
  final bytes = <int>[];
  for (final unit in command.codeUnits) {
    bytes.addAll(<int>[unit & 255, unit >> 8]);
  }
  final result = await Process.run(
    'powershell.exe',
    <String>['-NoProfile', '-EncodedCommand', base64Encode(bytes)],
  );
  return result.exitCode;
}

Future<bool> _connect(String handle) async {
  for (var attempt = 0; attempt < 5; attempt += 1) {
    try {
      final state = await _exchange(1, const <int>[]);
      if (state.phase == 3 && state.profileId == handle) return true;
      final result = await _exchange(2, <int>[
        ..._identifier('reconnect-${DateTime.now().microsecondsSinceEpoch}'),
        ..._identifier(handle),
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

Future<bool> _armeniaIpv4() async {
  for (final url in <String>[
    'https://api.ipify.org',
    'https://www.cloudflare.com/cdn-cgi/trace',
  ]) {
    final result = await Process.run('curl.exe', <String>[
      '-q',
      '--noproxy',
      '*',
      '-4',
      '--silent',
      '--connect-timeout',
      '4',
      '--max-time',
      '8',
      url,
    ]);
    final body = (result.stdout as String).trim();
    if (result.exitCode == 0 &&
        (body == '88.218.94.3' ||
            body.split('\n').any((line) => line.trim() == 'ip=88.218.94.3'))) {
      return true;
    }
  }
  return false;
}

Future<bool> _ipv6IsUnavailable() async {
  final result = await Process.run('curl.exe', <String>[
    '-q',
    '--noproxy',
    '*',
    '-6',
    '--silent',
    '--connect-timeout',
    '3',
    '--max-time',
    '5',
    'https://api64.ipify.org',
  ]);
  return result.exitCode != 0;
}

Future<void> main(List<String> arguments) async {
  var mutationStarted = false;
  String? handle;
  try {
    final before = await _exchange(1, const <int>[]);
    handle = before.profileId;
    if (before.phase != 3 ||
        before.killSwitchActive ||
        handle == null ||
        !handle.startsWith('xray-') ||
        !await _armeniaIpv4()) {
      stdout.writeln('RESULT=PRECONDITION_FAILED_NO_CHANGES');
      exitCode = 1;
      return;
    }
    stdout.writeln('PRECHECK=True');
    if (!arguments.contains('--apply')) return;

    mutationStarted = true;
    final installed = arguments.contains('--installer')
        ? await _installPackage()
        : await _install();
    stdout.writeln('INSTALL_EXIT=$installed');
    if (installed != 0 ||
        !await _connect(handle) ||
        !await _armeniaIpv4() ||
        !await _ipv6IsUnavailable()) {
      throw StateError('POSTCHECK_FAILED');
    }
    final state = await _exchange(1, const <int>[]);
    if (state.phase != 3 || state.killSwitchActive) {
      throw StateError('STATUS_FAILED');
    }
    stdout.writeln('IPV4_EXIT=ARMENIA IPV6_POLICY=BLOCKED');
    stdout.writeln('RESULT=UPDATED_AND_RECONNECTED');
  } on Object {
    if (mutationStarted && handle != null) {
      final rolledBack = await _install(rollback: true);
      final recovered =
          rolledBack == 0 && await _connect(handle) && await _armeniaIpv4();
      stdout.writeln('ROLLBACK_EXIT=$rolledBack RECOVERED=$recovered');
    }
    stdout.writeln('RESULT=UPDATE_NOT_COMPLETED');
    exitCode = 1;
  }
}
