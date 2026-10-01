import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

final class WireGuardConfigException implements Exception {
  const WireGuardConfigException(this.code);

  final String code;

  @override
  String toString() => 'WireGuardConfigException($code)';
}

final class WireGuardProvisioningProfile {
  WireGuardProvisioningProfile({
    required this.privateKey,
    required this.addresses,
    required this.dnsServers,
    required this.peerPublicKey,
    required this.presharedKey,
    required this.endpointHost,
    required this.endpointPort,
    required this.allowedIps,
    required this.persistentKeepalive,
  });

  final Uint8List privateKey;
  final List<String> addresses;
  final List<String> dnsServers;
  final Uint8List peerPublicKey;
  final Uint8List? presharedKey;
  final String endpointHost;
  final int endpointPort;
  final List<String> allowedIps;
  final int? persistentKeepalive;

  @override
  String toString() =>
      'WireGuardProvisioningProfile([REDACTED], addresses: ${addresses.length}, '
      'dns: ${dnsServers.length}, endpoint: [REDACTED], '
      'routes: ${allowedIps.length})';
}

final class WireGuardConfigParser {
  const WireGuardConfigParser();

  static const Set<String> _interfaceFields = <String>{
    'PrivateKey',
    'Address',
    'DNS',
  };
  static const Set<String> _peerFields = <String>{
    'PublicKey',
    'PresharedKey',
    'Endpoint',
    'AllowedIPs',
    'PersistentKeepalive',
  };

  WireGuardProvisioningProfile parse(String source) {
    if (source.length > 64 * 1024 || source.contains('\x00')) {
      throw const WireGuardConfigException('INVALID_PROFILE');
    }
    final Map<String, List<String>> interface = <String, List<String>>{};
    final Map<String, List<String>> peer = <String, List<String>>{};
    Map<String, List<String>>? current;
    var interfaceCount = 0;
    var peerCount = 0;

    for (final String original in const LineSplitter().convert(source)) {
      final String line = original.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
        continue;
      }
      if (line == '[Interface]') {
        interfaceCount += 1;
        current = interface;
        continue;
      }
      if (line == '[Peer]') {
        peerCount += 1;
        current = peer;
        continue;
      }
      final int separator = line.indexOf('=');
      if (current == null || separator <= 0) {
        throw const WireGuardConfigException('INVALID_PROFILE');
      }
      final String key = line.substring(0, separator).trim();
      final String value = line.substring(separator + 1).trim();
      final Set<String> allowed =
          identical(current, interface) ? _interfaceFields : _peerFields;
      if (!allowed.contains(key) || value.isEmpty) {
        throw const WireGuardConfigException('UNSUPPORTED_PROFILE_FIELD');
      }
      current.putIfAbsent(key, () => <String>[]).add(value);
    }
    if (interfaceCount != 1 || peerCount != 1) {
      throw const WireGuardConfigException('INVALID_PROFILE');
    }

    _requireSingle(interface, 'PrivateKey');
    _requireSingle(peer, 'PublicKey');
    _requireSingle(peer, 'Endpoint');
    _rejectDuplicate(peer, 'PresharedKey');
    _rejectDuplicate(peer, 'PersistentKeepalive');

    final List<String> addresses = _csv(interface['Address']);
    final List<String> dns = _csv(interface['DNS']);
    final List<String> allowedIps = _csv(peer['AllowedIPs']);
    _validateNetworks(addresses, minimum: 1, maximum: 8);
    if (dns.length > 8 ||
        dns.any((String value) => InternetAddress.tryParse(value) == null)) {
      throw const WireGuardConfigException('INVALID_DNS');
    }
    _validateNetworks(allowedIps, minimum: 1, maximum: 32);

    final ({String host, int port}) endpoint =
        _parseEndpoint(peer['Endpoint']!.single);
    final int? keepalive = _parseKeepalive(peer['PersistentKeepalive']);
    return WireGuardProvisioningProfile(
      privateKey: _decodeKey(interface['PrivateKey']!.single),
      addresses: List<String>.unmodifiable(addresses),
      dnsServers: List<String>.unmodifiable(dns),
      peerPublicKey: _decodeKey(peer['PublicKey']!.single),
      presharedKey: peer['PresharedKey'] == null
          ? null
          : _decodeKey(peer['PresharedKey']!.single),
      endpointHost: endpoint.host,
      endpointPort: endpoint.port,
      allowedIps: List<String>.unmodifiable(allowedIps),
      persistentKeepalive: keepalive,
    );
  }

  static void _requireSingle(Map<String, List<String>> section, String key) {
    if (section[key]?.length != 1) {
      throw const WireGuardConfigException('INVALID_PROFILE');
    }
  }

  static void _rejectDuplicate(Map<String, List<String>> section, String key) {
    if ((section[key]?.length ?? 0) > 1) {
      throw const WireGuardConfigException('INVALID_PROFILE');
    }
  }

  static List<String> _csv(List<String>? values) =>
      values
          ?.expand((String value) => value.split(','))
          .map((String value) => value.trim())
          .where((String value) => value.isNotEmpty)
          .toList(growable: false) ??
      const <String>[];

  static Uint8List _decodeKey(String value) {
    try {
      final Uint8List decoded = base64Decode(value);
      if (decoded.length != 32 || decoded.every((int byte) => byte == 0)) {
        throw const FormatException();
      }
      return decoded;
    } on FormatException {
      throw const WireGuardConfigException('INVALID_KEY');
    }
  }

  static void _validateNetworks(
    List<String> values, {
    required int minimum,
    required int maximum,
  }) {
    if (values.length < minimum || values.length > maximum) {
      throw const WireGuardConfigException('INVALID_NETWORK');
    }
    for (final String value in values) {
      final List<String> parts = value.split('/');
      final InternetAddress? address =
          parts.length == 2 ? InternetAddress.tryParse(parts.first) : null;
      final int? prefix = parts.length == 2 ? int.tryParse(parts.last) : null;
      final int maximumPrefix =
          address?.type == InternetAddressType.IPv4 ? 32 : 128;
      if (address == null ||
          prefix == null ||
          prefix < 0 ||
          prefix > maximumPrefix) {
        throw const WireGuardConfigException('INVALID_NETWORK');
      }
    }
  }

  static ({String host, int port}) _parseEndpoint(String value) {
    String host;
    String portText;
    if (value.startsWith('[')) {
      final int close = value.indexOf(']');
      if (close <= 1 || close + 2 >= value.length || value[close + 1] != ':') {
        throw const WireGuardConfigException('INVALID_ENDPOINT');
      }
      host = value.substring(1, close);
      portText = value.substring(close + 2);
      final InternetAddress? address = InternetAddress.tryParse(host);
      if (address?.type != InternetAddressType.IPv6) {
        throw const WireGuardConfigException('INVALID_ENDPOINT');
      }
    } else {
      final int separator = value.lastIndexOf(':');
      if (separator <= 0 || separator == value.length - 1) {
        throw const WireGuardConfigException('INVALID_ENDPOINT');
      }
      host = value.substring(0, separator);
      portText = value.substring(separator + 1);
      if (InternetAddress.tryParse(host) == null && !_validHostname(host)) {
        throw const WireGuardConfigException('INVALID_ENDPOINT');
      }
    }
    final int? port = int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) {
      throw const WireGuardConfigException('INVALID_ENDPOINT');
    }
    return (host: host, port: port);
  }

  static bool _validHostname(String value) =>
      value.length <= 253 &&
      !value.startsWith('.') &&
      !value.endsWith('.') &&
      value.split('.').every(
            (String label) =>
                label.isNotEmpty &&
                label.length <= 63 &&
                !label.startsWith('-') &&
                !label.endsWith('-') &&
                RegExp(r'^[A-Za-z0-9-]+$').hasMatch(label),
          );

  static int? _parseKeepalive(List<String>? values) {
    if (values == null) return null;
    final int? parsed = int.tryParse(values.single);
    if (parsed == null || parsed < 0 || parsed > 65535) {
      throw const WireGuardConfigException('INVALID_KEEPALIVE');
    }
    return parsed == 0 ? null : parsed;
  }
}
