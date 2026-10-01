import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_vpn_desktop/src/infrastructure/wireguard_config_parser.dart';

void main() {
  const WireGuardConfigParser parser = WireGuardConfigParser();
  final String privateKey = base64Encode(List<int>.filled(32, 7));
  final String publicKey = base64Encode(List<int>.filled(32, 9));

  String validConfig() => '''
[Interface]
PrivateKey = $privateKey
Address = 10.8.0.2/32, fd00::2/128
DNS = 1.1.1.1

[Peer]
PublicKey = $publicKey
Endpoint = vpn.example.test:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
''';

  test('parses a bounded WireGuard profile into typed fields', () {
    final WireGuardProvisioningProfile profile = parser.parse(validConfig());

    expect(profile.privateKey, hasLength(32));
    expect(profile.addresses, <String>['10.8.0.2/32', 'fd00::2/128']);
    expect(profile.dnsServers, <String>['1.1.1.1']);
    expect(profile.endpointHost, 'vpn.example.test');
    expect(profile.endpointPort, 51820);
    expect(profile.allowedIps, <String>['0.0.0.0/0', '::/0']);
    expect(profile.persistentKeepalive, 25);
  });

  test('rejects unknown fields, malformed keys, endpoint and routes', () {
    for (final String config in <String>[
      validConfig().replaceFirst('DNS =', 'PostUp ='),
      validConfig().replaceFirst(privateKey, 'not-a-key'),
      validConfig().replaceFirst('vpn.example.test:51820', 'bad host:51820'),
      validConfig().replaceFirst('0.0.0.0/0', '0.0.0.0/33'),
    ]) {
      expect(
          () => parser.parse(config), throwsA(isA<WireGuardConfigException>()));
    }
  });

  test('never renders key or endpoint through debug output', () {
    final WireGuardProvisioningProfile profile = parser.parse(validConfig());
    final String rendered = profile.toString();

    expect(rendered, contains('[REDACTED]'));
    expect(rendered, isNot(contains(privateKey)));
    expect(rendered, isNot(contains(publicKey)));
    expect(rendered, isNot(contains('vpn.example.test')));
  });
}
