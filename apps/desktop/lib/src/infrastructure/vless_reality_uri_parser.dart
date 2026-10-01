import 'dart:io';

import 'wireguard_config_parser.dart';

final class VlessRealityProvisioningProfile {
  const VlessRealityProvisioningProfile(
      {required this.clientId,
      required this.endpointHost,
      required this.endpointPort,
      required this.serverName,
      required this.fingerprint,
      required this.realityPassword,
      required this.shortId,
      required this.spiderX});
  final String clientId;
  final String endpointHost;
  final int endpointPort;
  final String serverName;
  final String fingerprint;
  final String realityPassword;
  final String shortId;
  final String spiderX;
  @override
  String toString() => 'VlessRealityProvisioningProfile([REDACTED])';
}

final class VlessRealityUriParser {
  const VlessRealityUriParser();
  static const Set<String> _requiredKeys = <String>{
    'type',
    'security',
    'flow',
    'sni',
    'fp',
    'pbk',
    'sid'
  };

  VlessRealityProvisioningProfile parse(String source) {
    if (source.length > 8 * 1024 || source.contains('\x00'))
      throw const WireGuardConfigException('INVALID_PROFILE');
    final Uri uri;
    try {
      uri = Uri.parse(source.trim());
    } on FormatException {
      throw const WireGuardConfigException('INVALID_PROFILE');
    }
    if (uri.scheme != 'vless' ||
        uri.userInfo.isEmpty ||
        uri.userInfo.contains(':') ||
        uri.host.isEmpty ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.path.isNotEmpty) {
      throw const WireGuardConfigException('INVALID_PROFILE');
    }
    final Set<String> actualKeys = uri.queryParametersAll.keys.toSet();
    if (!actualKeys.containsAll(_requiredKeys) ||
        actualKeys.length != _requiredKeys.length ||
        uri.queryParametersAll.values
            .any((List<String> values) => values.length != 1)) {
      throw const WireGuardConfigException('UNSUPPORTED_PROFILE_FIELD');
    }
    final Map<String, String> query = uri.queryParameters;
    if (query['type'] != 'raw' ||
        query['security'] != 'reality' ||
        query['flow'] != 'xtls-rprx-vision' ||
        query['fp'] != 'chrome') {
      throw const WireGuardConfigException('UNSUPPORTED_PROFILE_FIELD');
    }
    final String clientId = uri.userInfo.toLowerCase();
    final String serverName = query['sni']!;
    final String password = query['pbk']!;
    final String shortId = query['sid']!;
    const String spiderX = '/';
    if (!RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
            .hasMatch(clientId) ||
        !_validHost(uri.host) ||
        !_validHost(serverName) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(password) ||
        shortId.length > 16 ||
        shortId.length.isOdd ||
        !RegExp(r'^[0-9A-Fa-f]*$').hasMatch(shortId) ||
        spiderX.isEmpty ||
        spiderX.length > 256 ||
        !spiderX.startsWith('/') ||
        spiderX.runes.any((int rune) => rune < 32 || rune == 127)) {
      throw const WireGuardConfigException('INVALID_PROFILE');
    }
    return VlessRealityProvisioningProfile(
        clientId: clientId,
        endpointHost: uri.host,
        endpointPort: uri.port,
        serverName: serverName,
        fingerprint: 'chrome',
        realityPassword: password,
        shortId: shortId.toLowerCase(),
        spiderX: spiderX);
  }

  static bool _validHost(String value) {
    if (InternetAddress.tryParse(value) != null) return true;
    return value.length <= 253 &&
        !value.startsWith('.') &&
        !value.endsWith('.') &&
        value.split('.').every((String label) =>
            label.isNotEmpty &&
            label.length <= 63 &&
            !label.startsWith('-') &&
            !label.endsWith('-') &&
            RegExp(r'^[A-Za-z0-9-]+$').hasMatch(label));
  }
}
