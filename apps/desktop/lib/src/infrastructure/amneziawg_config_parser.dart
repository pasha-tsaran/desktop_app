import 'dart:convert';
import 'dart:typed_data';

import 'wireguard_config_parser.dart';

final class AmneziaWgProvisioningProfile {
  const AmneziaWgProvisioningProfile({
    required this.wireGuard,
    required this.jc,
    required this.jmin,
    required this.jmax,
    required this.s1,
    required this.s2,
    required this.s3,
    required this.s4,
    required this.h1,
    required this.h2,
    required this.h3,
    required this.h4,
    required this.specialJunk,
    required this.headerProtectionKey,
    required this.contentPaddingAddition,
    required this.rekeyAfterTime,
    required this.rekeyTimeout,
    required this.rejectAfterTime,
    required this.keepaliveTimeout,
    required this.maxHandshakeAttempts,
    required this.randomTrailers,
    required this.disableCookies,
    required this.mtu,
  });
  final WireGuardProvisioningProfile wireGuard;
  final int jc, jmin, jmax, s1, s2, s3, s4;
  final String h1, h2, h3, h4;
  final List<String> specialJunk;
  final Uint8List? headerProtectionKey;
  final String? contentPaddingAddition;
  final String? rekeyAfterTime;
  final String? rekeyTimeout;
  final String? rejectAfterTime;
  final String? keepaliveTimeout;
  final String? maxHandshakeAttempts;
  final bool? randomTrailers;
  final bool? disableCookies;
  final int? mtu;

  @override
  String toString() => 'AmneziaWgProvisioningProfile([REDACTED])';
}

final class AmneziaWgConfigParser {
  const AmneziaWgConfigParser({
    this.wireGuardParser = const WireGuardConfigParser(),
  });
  final WireGuardConfigParser wireGuardParser;
  static const Set<String> _awgFields = <String>{
    'Jc',
    'Jmin',
    'Jmax',
    'S1',
    'S2',
    'S3',
    'S4',
    'H1',
    'H2',
    'H3',
    'H4',
    'I1',
    'I2',
    'I3',
    'I4',
    'I5',
    'HeaderProtectionKey',
    'ContentPaddingAddition',
    'RekeyAfterTime',
    'RekeyTimeout',
    'RejectAfterTime',
    'KeepaliveTimeout',
    'MaxHandshakeAttempts',
    'RandomTrailers',
    'DisableCookies',
    'MTU',
  };

  AmneziaWgProvisioningProfile parse(String source) {
    if (source.length > 64 * 1024 || source.contains('\x00')) {
      throw const WireGuardConfigException('INVALID_PROFILE');
    }
    final Map<String, String> values = <String, String>{};
    final List<String> wireGuardLines = <String>[];
    var inInterface = false;
    for (final String original in const LineSplitter().convert(source)) {
      final String line = original.trim();
      if (line == '[Interface]') inInterface = true;
      if (line == '[Peer]') inInterface = false;
      final int separator = line.indexOf('=');
      final String key =
          separator > 0 ? line.substring(0, separator).trim() : '';
      if (_awgFields.contains(key)) {
        if (!inInterface || values.containsKey(key)) {
          throw const WireGuardConfigException('INVALID_PROFILE');
        }
        final String value = line.substring(separator + 1).trim();
        if (value.isEmpty ||
            value.length > 4096 ||
            value.runes.any((int rune) => rune < 32 || rune == 127)) {
          throw const WireGuardConfigException('INVALID_PROFILE');
        }
        values[key] = value;
      } else {
        wireGuardLines.add(original);
      }
    }
    for (final String key in const <String>[
      'Jc',
      'Jmin',
      'Jmax',
      'S1',
      'S2',
      'S3',
      'S4',
      'H1',
      'H2',
      'H3',
      'H4',
    ]) {
      if (!values.containsKey(key))
        throw const WireGuardConfigException('INVALID_PROFILE');
    }
    final int jc = _integer(values['Jc']!, 0, 10);
    // AWG 3.x permits small positive junk packets (the Netherlands profile
    // intentionally uses 10..50); legacy AWG 2.0 profiles commonly use 64+.
    final int jmin = _integer(values['Jmin']!, 1, 1024);
    final int jmax = _integer(values['Jmax']!, 1, 1024);
    if (jmin > jmax) throw const WireGuardConfigException('INVALID_PROFILE');
    final List<String> special = <String>[];
    var missing = false;
    for (var index = 1; index <= 5; index += 1) {
      final String? value = values['I$index'];
      if (value == null) {
        missing = true;
      } else {
        if (missing) throw const WireGuardConfigException('INVALID_PROFILE');
        special.add(value);
      }
    }
    final int s1 = _integer(values['S1']!, 0, 64);
    final int s2 = _integer(values['S2']!, 0, 64);
    final int s3 = _integer(values['S3']!, 0, 64);
    final int s4 = _integer(values['S4']!, 0, 32);
    final Uint8List? headerProtectionKey = _optionalKey(
      values['HeaderProtectionKey'],
    );
    final bool? randomTrailers = _optionalToggle(values['RandomTrailers']);
    if (headerProtectionKey != null &&
        (s1 < 12 || s2 < 12 || s3 < 12 || s4 < 12)) {
      throw const WireGuardConfigException('INVALID_PROFILE');
    }
    if (randomTrailers == true && !(s1 == s2 && s2 == s3 && s3 == s4)) {
      throw const WireGuardConfigException('INVALID_PROFILE');
    }
    return AmneziaWgProvisioningProfile(
      wireGuard: wireGuardParser.parse(wireGuardLines.join('\n')),
      jc: jc,
      jmin: jmin,
      jmax: jmax,
      s1: s1,
      s2: s2,
      s3: s3,
      s4: s4,
      h1: _range(values['H1']!),
      h2: _range(values['H2']!),
      h3: _range(values['H3']!),
      h4: _range(values['H4']!),
      specialJunk: List<String>.unmodifiable(special),
      headerProtectionKey: headerProtectionKey,
      contentPaddingAddition: _optionalRange16(
        values['ContentPaddingAddition'],
      ),
      rekeyAfterTime: _optionalRange16(values['RekeyAfterTime']),
      rekeyTimeout: _optionalRange16(values['RekeyTimeout']),
      rejectAfterTime: _optionalRange16(values['RejectAfterTime']),
      keepaliveTimeout: _optionalRange16(values['KeepaliveTimeout']),
      maxHandshakeAttempts: _optionalRange16(values['MaxHandshakeAttempts']),
      randomTrailers: randomTrailers,
      disableCookies: _optionalToggle(values['DisableCookies']),
      mtu: _optionalMtu(values['MTU']),
    );
  }

  static int? _optionalMtu(String? value) =>
      value == null ? null : _integer(value, 576, 9000);

  static int _integer(String value, int minimum, int maximum) {
    final int? parsed = int.tryParse(value);
    if (parsed == null || parsed < minimum || parsed > maximum) {
      throw const WireGuardConfigException('INVALID_PROFILE');
    }
    return parsed;
  }

  static String _range(String value) {
    final RegExpMatch? match = RegExp(r'^(\d+)(?:-(\d+))?$').firstMatch(value);
    if (match == null) throw const WireGuardConfigException('INVALID_PROFILE');
    final int start = int.parse(match.group(1)!);
    final int end = int.parse(match.group(2) ?? match.group(1)!);
    if (start > 0xffffffff || end > 0xffffffff || start > end) {
      throw const WireGuardConfigException('INVALID_PROFILE');
    }
    return value;
  }

  static String? _optionalRange16(String? value) {
    if (value == null) return null;
    final String checked = _range(value);
    final Iterable<int> parts = checked.split('-').map(int.parse);
    if (parts.any((int part) => part > 0xffff)) {
      throw const WireGuardConfigException('INVALID_PROFILE');
    }
    return checked;
  }

  static Uint8List? _optionalKey(String? value) {
    if (value == null) return null;
    try {
      final Uint8List decoded = base64Decode(value);
      if (decoded.length != 32 || base64Encode(decoded) != value) {
        throw const FormatException();
      }
      return decoded;
    } on FormatException {
      throw const WireGuardConfigException('INVALID_PROFILE');
    }
  }

  static bool? _optionalToggle(String? value) => switch (value) {
        null => null,
        'on' => true,
        'off' => false,
        _ => throw const WireGuardConfigException('INVALID_PROFILE'),
      };
}
