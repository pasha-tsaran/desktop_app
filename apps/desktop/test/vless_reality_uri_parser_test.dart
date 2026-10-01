import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_vpn_desktop/src/infrastructure/vless_reality_uri_parser.dart';
import 'package:kenai_vpn_desktop/src/infrastructure/wireguard_config_parser.dart';

void main() {
  String clientId() =>
      <int>[8, 4, 4, 4, 12].map((int length) => 'a' * length).join('-');
  String profile({String suffix = ''}) =>
      'vless://${clientId()}@vpn.example.test:443?'
      'type=raw&security=reality&flow=xtls-rprx-vision&'
      'sni=cover.example.test&fp=chrome&pbk=${'A' * 43}&sid=aabbccdd$suffix';

  test('accepts only the server VLESS RAW REALITY Vision contract', () {
    final VlessRealityProvisioningProfile parsed =
        const VlessRealityUriParser().parse(profile());

    expect(parsed.endpointHost, 'vpn.example.test');
    expect(parsed.endpointPort, 443);
    expect(parsed.serverName, 'cover.example.test');
    expect(parsed.fingerprint, 'chrome');
    expect(parsed.shortId, 'aabbccdd');
    expect(parsed.spiderX, '/');
    expect(parsed.toString(), isNot(contains(clientId())));
  });

  test('rejects alternate transports, duplicate and injected parameters', () {
    final VlessRealityUriParser parser = const VlessRealityUriParser();
    for (final String invalid in <String>[
      profile().replaceFirst('type=raw', 'type=ws'),
      profile().replaceFirst('security=reality', 'security=tls'),
      profile().replaceFirst('flow=xtls-rprx-vision', 'flow='),
      profile(suffix: '&sid=0011'),
      profile(suffix: '&unknown=value'),
      profile().replaceFirst('sid=aabbccdd', 'sid=abc'),
    ]) {
      expect(
        () => parser.parse(invalid),
        throwsA(isA<WireGuardConfigException>()),
      );
    }
  });
}
